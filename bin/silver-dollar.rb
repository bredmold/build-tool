#!/usr/bin/env ruby
#
# silver-dollar - Update a bunch of projects from Git and build them

require 'pathname'
require 'io/console'
require 'set'

script_path = Pathname.new(__FILE__).realpath
script_dir = File.dirname(script_path)
bde_root = File.dirname(script_dir)
bde_ruby = File.expand_path('ruby', bde_root)

$: << bde_ruby

require 'silver_dollar_options.rb'
require 'stopwatch.rb'
require 'git_repo.rb'
require 'git_svn_repo.rb'
require 'git_svn_repo.rb'
require 'shell_utils.rb'
require 'mvn_project.rb'

begin
  options = SilverDollarOptions.new
  $options = options.parse(ARGV)
rescue OptionParser::MissingArgument => ma
  puts "Option parsing: #{ma}"
  exit 1
rescue ArgumentError => ae
  puts "Option validation: #{ae}"
  exit 1
end

#
# Strategy for locating the build file:
#  1. Command-line option (highest precedence)
#  2. Existence of 'silver-dollar.rb' file in the working directory
#  3. Environment variable
#

$build_file = $options[:build_file]
if $build_file && !(File.exists? $build_file)
  puts 'Searching for build file in SILVER_DOLLAR env variable'
  $build_file = ENV['SILVER_DOLLAR']
end
unless $build_file
  puts 'Could not locate build file'
  exit 1
end

unless File.exist? $build_file
  puts "Cannot open the build file: #{$build_file}"
  exit 1
end

$build_str = IO.read $build_file
$build_content = eval $build_str

#
# Locate the project folder
#

$project_dir = $options[:project_dir] || $build_content[:config][:project_dir]
unless File.exist? $project_dir
  puts "Unable to locate projects directory #{$project_dir}"
  exit 1
end


# Operate on the various branch lists... pull from the following sources in priority from lowest to highest
#  1. built-in defaults
#  2. options file
#  3. command-line

$pull_branches       = $options[:pull_branches]   || $build_content[:config][:pull_branches]   || ['master']
$rebase_branches     = $options[:rebase_branches] || $build_content[:config][:rebase_branches] || []
$local_branches      = $options[:local_branches]  || $build_content[:config][:local_branches]  || []
$global_basis_branch = $options[:basis_branch]    || $build_content[:config][:basis_branch]    || 'master'

pull_set = Set.new $pull_branches
rebase_set = Set.new $rebase_branches
local_set = Set.new $local_branches
if pull_set.intersect? rebase_set
  puts "The following branches are both pull and rebase branches: #{pull_set.intersection(rebase_set).to_a}"
  exit 1
elsif pull_set.intersect? local_set
  puts "The following branches are both pull and local branches: #{pull_set.intersection(local_set).to_a}"
  exit 1
elsif rebase_set.intersect? local_set
  puts "The following branches are both rebase and local branches: #{rebase_set.intersection(local_set).to_a}"
  exit 1
end

#
# Option reporting
#
unless $options[:project_list].empty?
  printf "Only building selected projects: %s\n", $options[:project_list].join(' ')
end

if $options[:auto_reset]
  puts 'Auto-reset enabled - running git reset on all projects after build'
end

puts "    Execution phases: #{$options[:phases]}"
puts "       Pull branches: #{$pull_branches}"
puts "     Rebase branches: #{$rebase_branches}"
puts "      Local branches: #{$local_branches}"
puts "Default basis branch: #{$global_basis_branch}"

$stopwatches = Stopwatch.new
$stopwatches.start :silver_dollar

def extract_project(desc)
  if desc[:library]
    desc[:library]
  elsif desc[:service]
    desc[:service]
  else
    puts "Invalid desc: #{desc}"
    exit 1
  end
end

def extract_repository(desc)
  desc[:repo] || extract_project(desc)
end

def branch_report(descs)
  format = "%-20s %5s %7s %s\n"
  printf(format, 'Project', '# Mod', 'Commit', 'Branch')
  printf(format, '=======', '=====', '======', '======')
  descs.each do |desc|
    repo_name = extract_repository(desc)
    project = extract_project(desc)
    project_name = (repo_name == project) ? project : "#{repo_name}/#{project}"
    repository = File.expand_path(repo_name, $project_dir)
    git_repo = GitRepository.new(repository)
    printf(format, project_name, git_repo.status.length, git_repo.commit_id, git_repo.current_branch)
  end
end

def guess_git_repo_type(dot_git)
  git_svn = false
  config = File.expand_path('config', dot_git)
  File.open(config) do |config_file|
    config_file.each_line do |config_line|
      if config_line =~ /^\[svn-remote "\S+"\]$/
        git_svn = true
      end
    end
  end
  git_svn ? 'git-svn' : 'git'
end

def guess_repo_type(path)
  dot_git = File.expand_path('.git', path)
  dot_svn = File.expand_path('.svn', path)

  if File.exists? dot_git
    guess_git_repo_type(dot_git)
  elsif File.exists? dot_svn
    'svn'
  else
    'none'
  end
end

def initialize_repo(desc, path)
  repo_type = guess_repo_type(path)
  if desc[:scm]
    puts "Over-riding repo type #{repo_type} with config value #{desc[:scm]} for #{path}"
    repo_type = desc[:scm]
  end

  case repo_type
    when 'git'
      GitRepository.new path
    when 'git-svn'
      GitSvnRepository.new path
    when 'none'
      puts "No .git or .svn folder was found under #{path}"
      exit 1
    else
      puts "Don't know how to handle #{repo_type} at #{path}"
      exit 1
  end
end

# Build a service from a service description. The service description can either be a string
# giving the project name, or it can be a record describing the service. If it's a simple string,
# it will be interpreted as though it were a record containing only the project name.
#
# The project record has these fields:
# NAME     DESCRIPTION
# service             - project name for a service (either this or library are required)
# library             - project name for a library (either this or service are required)
# downstream OPTIONAL - list of projects that directly depend on this one
# archive    OPTIONAL - name of the generated WAR file (default = $project.war)
# wlp        OPTIONAL - name of the WLP instance to deploy to (default = $normalized_project.war)
#
# The 'normalized project' is the project name with any recognized suffix removed. The only
# recognized suffix is '-service' (e.g. project 'ari-service' has a default service name of 'ari').
def initialize_project(project_desc)
  project_name = extract_project(project_desc)
  repo_name = extract_repository(project_desc)
  repo_path = File.expand_path(repo_name, $project_dir)
  repo = initialize_repo(project_desc, repo_path)
  if project_desc[:library]
    Project::Library.new(
        repository: repo,
        sub_project: (project_name == repo_name) ? nil : project_name,
        auto_reset: $options[:auto_reset],
        mvn_flags: project_desc[:mvn_flags],
        pull_branches: $pull_branches,
        rebase_branches: $rebase_branches,
        local_branches: $local_branches,
        basis_branch: project_desc[:basis_branch] || $global_basis_branch,
        always_build: project_desc[:always_build]
    )
  else
    Project::Service.new(
        repository: repo,
        sub_project: (project_name == repo_name) ? nil : project_name,
        archive: project_desc[:archive],
        service: project_desc[:wlp],
        restart: project_desc[:restart],
        auto_reset: $options[:auto_reset],
        mvn_flags: project_desc[:mvn_flags],
        pull_branches: $pull_branches,
        rebase_branches: $rebase_branches,
        local_branches: $local_branches,
        basis_branch: project_desc[:basis_branch] || $global_basis_branch
    )
  end
end

# Build the things!
def build_the_world(descs)
  puts 'Building project dependency model'

  p_list = descs.collect { |d| initialize_project(d) }
  p_list = p_list.select { |p| $options[:project_list].empty? || $options[:project_list].include?(p.project) }
  STDOUT.flush

  projects = Project::ProjectSet.new(p_list)
  if projects.empty?
    puts 'There are no projects to build'
    exit 0
  end

  projects.tsort.each do |project|
    $stopwatches.start project.project
    if $options[:phases].include? :sync
      project.sync
    end
    if $options[:phases].include? :build
      project.build
    end
    if $options[:phases].include? :deploy
      project.deploy
    end
    if project.dirty_fail?
      project.downstream.each do |dp_artifact|
        dproj = projects[dp_artifact]
        unless dproj.nil?
          puts "Marking 'dirty fail' condition for #{dproj.project}"
          dproj.upstream_fail
        end
      end
    end
    $stopwatches.stop project.project
  end

  format = "%-20s %-6s %12s  %s\n"
  printf format, 'Project', 'Time', 'Build Status', 'Branch'
  printf format, '=======', '====', '============', '======'

  projects.each_value { |p| printf format, p.project, $stopwatches.format(p.project), p.build_status, p.current_branch }
  printf format, '=====', '=====', '', ''
  printf format, 'TOTAL', $stopwatches.format(:silver_dollar), '', ''
end

# This method is just here because I want the descs list at the very bottom of the file
def process_descs(descs)
  if $options[:readonly]
    branch_report descs
  else
    build_the_world descs
  end
end

process_descs $build_content[:projects]
