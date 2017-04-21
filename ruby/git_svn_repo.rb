require 'git_repo.rb'

class GitSvnRepository < GitRepository
  include ShellTools

  def initialize(repository)
    super(repository)
  end

  def pull
    puts "git svn rebase #{@repository}"
    STDOUT.flush
    Dir.chdir @repository
    system 'git svn rebase'
    verify_status($?, 'git svn rebase')
  end

  def fetch(remote)
    puts "git svn fetch #{@project}"
    STDOUT.flush
    Dir.chdir @repository
    system('git', 'svn', 'rebase')
    verify_status($?, 'git svn fetch')
  end
end