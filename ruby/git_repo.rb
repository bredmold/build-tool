require 'shell_utils.rb'

class GitRepository
  include ShellTools

  def initialize(repository)
    @repository = repository
    @project = File.basename(@repository)
  end

  attr_reader :repository, :project

  def repo_exists
    File.exists? @repository
  end

  def to_s
    @repository
  end

  def clone(origin)
    origin = "git@scm.appleleisuregroup.com:alg/#{@project}.git"
    puts "Cloning repository from URL #{origin}"
    system "git clone #{origin} #{@repository}"
    verify_status($?, "git clone #{origin} #{@repository}")
  end

  def pull
    puts "Pulling repository #{@repository}"
    Dir.chdir @repository
    system 'git pull --ff-only'
    verify_status($?, 'git pull')
  end

  def fetch(remote)
    puts "Fetch #{@project} #{remote}"
    Dir.chdir @repository
    system('git', 'fetch', remote)
    verify_status($?, "git fetch #{remote}")
  end

  def rebase(branch)
    puts "Rebase #{@project} #{branch}"
    Dir.chdir @repository
    system('git', 'rebase', branch)
    verify_status($?, "git rebase #{branch}")
  end

  def commit_id
    Dir.chdir @repository
    commit = `git log -n 1 --format=%h`
    verify_status($?, 'git log -n 1 --format=%h')
    commit.chomp
  end

  # Returns the current git repository branch - or <MISSING REPO> if there is no local repo.
  # This method assumes that the @repo_exists boolean value is set
  def current_branch
    if File.exists? @repository
      Dir.chdir @repository
      actual_branch = `git rev-parse --abbrev-ref HEAD`.chomp
      verify_status($?, 'git rev-parse')
      actual_branch
    else
      '<MISSING REPO>'
    end
  end

  # If it's not already present, add the state file to local exclusions
  def save_local_exclusion(exclude_entry)
    exclusions_file = File.expand_path('.git/info/exclude', @repository)
    if File.exists?(exclusions_file)
      exclusion_lines = IO.readlines(exclusions_file)
      exclusions = exclusion_lines.collect { |l| l.chomp }
    else
      exclusions = []
    end

    unless exclusions.include? exclude_entry
      exclusions << exclude_entry
      exclusions = exclusions.collect { |l| "#{l}\n" }
      IO.write(exclusions_file, exclusions.join)
    end
  end

  # Returns a list of modified workspace files (list is empty if workspace is clean)
  def status
    Dir.chdir @repository
    status = `git status -s`
    verify_status($?, 'git status -s')
    status.lines
  end

  def hard_reset
    Dir.chdir @repository
    system 'git reset --hard HEAD'
    verify_status($?, 'git reset --hard HEAD')
  end
end