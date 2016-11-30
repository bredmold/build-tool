require 'optparse'

class SilverDollarOptions
  def initialize
    @options = {
        project_dir: nil,
        build_file: 'silver-dollar.rb',
        readonly: false,
        auto_reset: false,
        project_list: [],
        phases: [:sync, :build, :deploy],
        pull_branches: nil,
        rebase_branches: nil,
        local_branches: nil,
        basis_branch: nil,
    }
  end

  def parse(arguments)
    OptionParser.new do |opts|
      opts.banner = 'Usage: silver-dollar [options]'

      opts.on('-f', '--build-file BUILDFILE',
              'build file - where configuration and project list lives') do |buildfile|
        @options[:build_file] = buildfile
      end

      opts.on('-r', '--readonly',
              'read-only mode - prints the current branch in each repo') do |readonly|
        @options[:readonly] = readonly
      end

      opts.on('-P', '--phases PHASESLIST',
              'Execute only certain phases (sync, build, deploy)') do |phases|
        stripped = phases.split(/,/).collect { |s| s.strip.downcase.to_sym }
        @options[:phases] = stripped.reject { |s| s.empty? }
      end

      opts.on('-R', '--auto-reset',
              'Reset the workspace if the build modifies any files') do |auto_reset|
        @options[:auto_reset] = auto_reset
      end

      opts.on('-d', '--projects-dir DIRECTORY',
              'Root project folder - default is ~/Projects') do |project_dir|
        @options[:project_dir] = File.expand_path(project_dir)
      end

      opts.on('-m', '--pull-branches BRANCHES',
              'List of branches to pull instead of rebase') do |branches|
        stripped = branches.split(/,/).collect { |s| s.strip }
        @options[:pull_branches] = stripped.reject { |s| s.empty? }
      end

      opts.on('-b', '--rebase-branches BRANCHES',
              'List of branches to rebase against the basis branch') do |branches|
        stripped = branches.split(/,/).collect { |s| s.strip }
        @options[:rebase_branches] = stripped.reject { |s| s.empty? }
      end

      opts.on('-l', '--local-branches BRANCHES',
              'List of branches that are left alone, neither pull nor rebase') do |branches|
        stripped = branches.split(/,/).collect { |s| s.strip }
        @options[:local_branches] = stripped.reject { |s| s.empty? }
      end

      opts.on('-B', '--basis-branch BRANCH',
              'Basis branch when re-basing - this is over-ridden by project config') do |branch|
        @options[:basis_branch] = branch.strip
      end

      opts.on_tail('-h', '--help', 'Show this message') do
        puts opts
        exit
      end
    end.parse!(arguments)

    @options[:project_list] = ARGV

    validate

    @options
  end

  # Validate a set of options - if the options are not valid, then
  def validate
    if !@options[:project_list].empty? && @options[:readonly]
      msg = sprintf "Project list given in read-only mode: %s\n", @options[:project_list].join(' ')
      raise ArgumentError.new msg
    end

    if @options[:phases].empty?
      raise ArgumentError.new 'No execution phases were specified'
    end

    valid_phases = [:sync, :build, :deploy]
    @options[:phases].each do |phase|
      unless valid_phases.include? phase
        raise ArgumentError.new "Unknown phase: #{phase}"
      end
    end
  end
end
