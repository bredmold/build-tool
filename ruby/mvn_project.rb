# Logic about maven projects

require 'rexml/document'
require 'tsort'
require 'xml_utils.rb'

module Project
  STATE_FILE_NAME = '.silver-dollar'
  LOG_FILE_NAME = '.mvn.log'

  class Artifact
    include XmlUtils

    def initialize(elt, parent)
      @group = element_text(elt, 'groupId', parent ? parent.group : nil)
      @artifact = element_text(elt, 'artifactId', parent ? parent.artifact : nil)
    end

    attr_reader :group, :artifact

    def ==(o)
      @group == o.group &&
          @artifact == o.artifact
    end

    alias eql? ==

    def hash
      @group.hash ^ @artifact.hash
    end

    def to_s
      "A:#{@group}:#{@artifact}"
    end
  end

  class Dependency < Artifact
    def initialize(dep_elt, scope: false)
      super(dep_elt, nil)

      if scope.is_a? String
        @scope = scope
      else
        scope_elt = dep_elt.elements.collect('scope') { |e| e }.first
        @scope = scope_elt ? scope_elt.text : 'compile'
      end
    end

    attr_reader :scope

    def to_s
      "D:#{@group}:#{@artifact}:#{@scope}"
    end
  end

  class ProjectDependency < Artifact
    def initialize(artifact, project)
      @group = artifact.group
      @artifact = artifact.artifact
      @project = project
    end

    attr_reader :project

    def to_s
      "P:#{@group}:#{@artifact}:#{project.project}"
    end
  end

  # A thing that we build and sync. In theory, one could say that Library and Service should share
  # a common base-class called Project, but that wrinkle isn't yet needed, so I'm not doing it.
  class Library
    include ShellTools
    include REXML

    def initialize(
        repository:,
        sub_project: nil,
        auto_reset: false,
        mvn_flags: nil,
        pull_branches: nil,
        rebase_branches: nil,
        local_branches: nil,
        basis_branch: nil,
        always_build: false)
      @auto_reset = auto_reset
      @mvn_flags = mvn_flags || []
      @git_repo = repository
      @project_path = sub_project ? "#{@git_repo.repository}/#{sub_project}" : @git_repo.repository
      @state_file = File.expand_path(STATE_FILE_NAME, @project_path)
      @log_file = File.expand_path(LOG_FILE_NAME, @project_path)
      @downstream = []
      @build_status = 'new'
      @pull_branches = pull_branches
      @rebase_branches = rebase_branches
      @local_branches = local_branches
      @basis_branch = basis_branch
      @always_build = always_build

      if basis_branch
        @pull_branches << basis_branch
      end

      read_pom

      @bad_sync_states = %w(dirty-fail upstream-fail missing bad-branch)
    end

    attr_reader :upstream, :build_status, :artifact, :project_path
    attr_accessor :downstream

    # Synchronize a project - this is mostly about manipulating (or not manipulating) git.
    def sync
      if 'dirty-fail' == @build_status
        puts "#{@git_repo.project}: Skipping sync because of dirty fail condition"
      elsif 'upstream-fail' == @build_status
        puts "#{@git_repo.project}: Skipping sync because of upstream fail condition"
      elsif !@git_repo.repo_exists
        puts "Project #{@git_repo.project} has no local repository - skipping"
        @build_status = 'missing'
      elsif is_pull_branch
        verify_clean_workspace
        @git_repo.pull
        @build_status = 'pull'
      elsif is_rebase_branch
        verify_clean_workspace
        @git_repo.fetch 'origin'
        @git_repo.rebase "origin/#{@basis_branch}"
        @build_status = 'rebase'
      elsif is_local_branch && @auto_reset
        verify_clean_workspace
        puts "Skipping sync for #{@git_repo.project} on project branch #{@branch}"
        @build_status = 'local'
      elsif is_local_branch
        puts "Skipping sync for #{@git_repo.project} on project branch #{@branch}"
        @build_status = 'local'
      else
        puts "Branch #{@git_repo.current_branch} is not a recognized branch for pull, rebase or local - skipping"
        @build_status = 'bad-branch'
      end
    end

    # Build a project - this means we call 'mvn clean install' - in some future iteration,
    # we may include the option for different Maven invocations, or even entirely new build
    # steps.
    def build
      if should_build
        if @auto_reset
          status = @git_repo.status
          if [] != status
            file_or_files = (status.length == 1) ? 'file' : 'files'
            puts "#{@git_repo.project}: #{status.length} modified #{file_or_files} - aborting the build"
            @build_status = 'dirty'
            return
          end
        end

        @git_repo.save_local_exclusion LOG_FILE_NAME
        mvn_command = ['mvn', '-f', "#{@project_path}/pom.xml", '-l', @log_file]
        @mvn_flags.each do |flag|
          mvn_command << flag
        end
        mvn_command << 'clean' << 'install'
        puts "#{@git_repo.project}: #{mvn_command.join ' '}"
        system *mvn_command
        if report_status $?, mvn_command.join(' ')
          @build_status = 'build'
          save_build_state
          File.unlink @log_file

          if @auto_reset
            status = @git_repo.status
            if [] != status
              puts "#{@git_repo.project}: #{status.length} modified files - resetting the workspace"
              @git_repo.hard_reset
            end
          end
        else
          puts "#{@git_repo.project}: build failed - see #{@log_file} for details"
          summarize_build_failure
          @build_status = 'fail'
        end
      end
    end

    def deploy
      # For a library, this does nothing
    end

    def dirty_fail?
      ('dirty-fail' == @build_status) ||
          ('upstream-fail' == @build_status) ||
          (('fail' == @build_status) && has_local_changes)
    end

    def upstream_fail
      @build_status = 'upstream-fail'
    end

    def current_branch
      @git_repo.current_branch
    end

    def project
      sub_project = File.basename(@project_path)
      project = @git_repo.project
      (project == sub_project) ? project : "#{project}/#{sub_project}"
    end

    private

    # Attempt to print some summary lines from a Maven build failure
    def summarize_build_failure
      if File.exists? @log_file
        mvn_lines = IO.readlines(@log_file)
        mvn_lines = mvn_lines.collect { |l| l.chomp }

        test_failures(mvn_lines)
      end
    end

    # Track down the test failures section at the end of the Maven log and print it out
    # return true if any text was printed
    def test_failures(mvn_lines)
      summary = mvn_lines.reduce({in_tests_section: false, lines: []}) do |memo, line|
        if memo[:in_tests_section]
          if line.strip.empty?
            memo[:in_tests_section] = false
          else
            memo[:lines] << line
          end
        elsif line.start_with? 'Failed tests:'
          memo[:in_tests_section] = true
          memo[:lines] << line
        end
        memo
      end

      unless summary[:lines].empty?
        lines = summary[:lines].collect { |l| "#{l}\n" }
        puts lines.join
      end

      summary[:lines].empty?
    end

    # Use maven to read the project dependencies and figure out candidates for dependency resolution
    def read_pom
      if @git_repo.repo_exists
        pom_file = File.expand_path('pom.xml', @git_repo.repository)
        puts "pom_file = #{pom_file}"
        pom_doc = Document.new(File.new(pom_file))
        deps = pom_doc.elements.collect('project/dependencies/dependency') do |dep|
          Dependency.new(dep)
        end

        parent_ref = nil
        pom_doc.elements.each('project/parent') do |parent|
          parent_ref = Dependency.new(parent, scope: 'parent')
          deps << parent_ref
          puts "parent #{parent_ref}"
        end

        @upstream = deps.select do |dep|
          dep.scope == 'compile' || dep.scope == 'parent'
        end

        project_elt = pom_doc.elements.each('project') { |e| e }.first
        @artifact = Artifact.new(project_elt, parent_ref)

        @build_status = 'pom'
        STDOUT.flush
      end
    end

    def is_pull_branch
      @pull_branches.include? @git_repo.current_branch
    end

    def is_rebase_branch
      @rebase_branches.include? @git_repo.current_branch
    end

    def is_local_branch
      @local_branches.include? @git_repo.current_branch
    end

    def should_build
      if @always_build
        puts 'Always-build flag forces a build regardless of SCM status'
      end
      @always_build ||
          (!@bad_sync_states.include?(@build_status) && @git_repo.repo_exists && !commit_id_matches)
    end

    def has_local_changes
      # TODO distinguish between 'pull branch' and 'trunk branch'
      !is_pull_branch || (@git_repo.status != [])
    end

    # Return true if the current commit ID matches the commit ID saved in the build state
    def commit_id_matches
      saved_commit_id = read_build_state
      current_commit_id = git_commit_id
      if !saved_commit_id.nil? && (saved_commit_id == current_commit_id)
        puts "#{project}: current commit ID matches saved commit ID - skipping build (#{saved_commit_id})"
        @build_status = 'up-to-date'
        true
      else
        false
      end
    end

    # Read build state - if it is hex digits, return it, else return nil
    def read_build_state
      if File.exists? @state_file
        build_state = IO.read(@state_file).chomp
        if is_valid_commit_id build_state
          return build_state
        end
      end
      nil
    end

    # As an optimization - save the commit ID of a successful build in the repository
    # Add the state file to the local exclusions in the repository
    def save_build_state
      save_commit_id(git_commit_id)
      @git_repo.save_local_exclusion STATE_FILE_NAME

      mark_downstream_projects
    end

    # For downstream projects (if there are any) remove their build states to force a build
    def mark_downstream_projects
      @downstream.each do |dp|
        dp_status = File.expand_path(STATE_FILE_NAME, dp.project.project_path)
        if File.exists? dp_status
          puts "#{@git_repo.project}: Invalidating build state for #{dp}"
          File.unlink dp_status
        end
      end
    end

    # Save the given commit ID to the state file
    def save_commit_id(commit_id)
      if is_valid_commit_id commit_id
        IO.write(@state_file, commit_id)
      end
    end

    # returns true if the commit ID is a 40-digit hex string
    def is_valid_commit_id(commit_id)
      !commit_id.nil? && commit_id.match(/^[a-fA-F0-9]{40}$/)
    end

    # Returns the current commit ID, if the workspace is clean - else returns nil
    def git_commit_id
      modified_files = @git_repo.status
      if modified_files.empty?
        commit_id = `git log -n 1 --format='%H'`
        verify_status($?, 'git log -n 1 --format=%H')
        commit_id.chomp
      else
        nil
      end
    end

    def verify_repository
      unless File.exists? @git_repo.repository
        puts "No such repository: #{@git_repo.repository}"
        exit 1
      end
      Dir.chdir(@git_repo.repository)
    end

    # Fails if the workspace is not clean
    def verify_clean_workspace
      file_lines = @git_repo.status
      unless file_lines.empty?
        puts "Workspace #{@git_repo.repository} is not clean:"
        files = file_lines.collect do |line|
          line =~ /^.*:\s+(\S+)/
          $1
        end
        files.sort.uniq.each do |line|
          puts "\t#{line}"
        end
        exit 1
      end
    end
  end

  # In addition to sync and build, one may deploy a service
  class Service < Library
    def initialize(
        repository:,
        archive:,
        service:,
        restart: true,
        sub_project: nil,
        auto_reset: false,
        mvn_flags: nil,
        pull_branches: nil,
        rebase_branches: nil,
        local_branches: nil,
        basis_branch: nil)
      super(
          repository: repository,
          sub_project: sub_project,
          auto_reset: auto_reset,
          mvn_flags: mvn_flags,
          pull_branches: pull_branches,
          rebase_branches: rebase_branches,
          local_branches: local_branches,
          basis_branch: basis_branch,
          always_build: false)

      @restart = should_restart restart
      @archive = select_archive archive
      @service = select_service service
    end

    # Deploy a service to the development VM - this involves calling out to the deploy shell
    # script.
    def deploy
      if @git_repo.repo_exists && (@build_status == 'build')
        system 'dev-deploy', "#{@project_path}/target/#{@archive}", @service, (@restart ? 'true' : 'false')
        verify_status($?, "dev-deploy #{@project_path}/target/#{@archive} #{@service} #{@restart}")
        @build_status = 'deploy'
      end
    end

    private

    def should_restart(restart_config)
      if restart_config.nil?
        true
      elsif restart_config.kind_of? String
        ["true", "yes"].include? restart_config
      else
        restart_config
      end
    end

    def select_archive(archive_selector)
      (archive_selector.is_a? String) ? archive_selector : "#{File.basename @project_path}.war"
    end

    def select_service(service_selector)
      (service_selector.is_a? String) ? service_selector : normalize_project
    end

    def normalize_project
      project.gsub(/-service$/, '')
    end
  end

  class ProjectSet
    include TSort

    def initialize(projects)
      @projects = projects.reduce({}) do |pmap, p|
        pmap[p.artifact] = p
        pmap
      end

      @projects.each_value do |dproj|
        dproj.upstream.each do |dep|
          uproj = @projects[dep]
          unless uproj.nil?
            uproj.downstream << ProjectDependency.new(dproj.artifact, dproj)
          end
        end
      end
    end

    def tsort_each_node(&block)
      @projects.each_value(&block)
    end

    def tsort_each_child(project, &block)
      children = project.upstream.collect { |pa| @projects[pa] }
      children = children.select { |c| c }
      children.each(&block)
    end

    def empty?
      @projects.empty?
    end

    def each_value(&block)
      @projects.each_value(&block)
    end
  end
end