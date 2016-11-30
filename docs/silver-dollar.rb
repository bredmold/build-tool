# Example silver-dollar.rb configuration file
{
    # Configuration section - affecting how silver-dollar operates
    config: {
        # Your Git clones live here
        project_dir: File.expand_path('~/Projects'),

        # List of branches that silver-dollar knows about by default
        pull_branches: ['master', 'develop'],

        # Default basis branch for rebase operations
        basis_branch: 'develop',
    },

    # Projects section - these are the projects you want to build
    projects: [
        # This project always builds, regardless of SCM state
        {library: 'shutdown-services', always_build: true},

        # Ordinary library build
        {library: 'config'},

        # Ordinary library build with custom Maven options
        {library: 'data', mvn_flags: ['-Pclean-db']},

        # Library build that is a Maven sub-project in a higher-level repository
        {library: 'sub-project', repo: 'core'},

        # Simple service build with stock assumptions
        {service: 'service'},

        # Service build with custom archive name
        {service: 'foo-service', archive: 'foo.war'},

        # Service build that changes some deployment properties (likely to change)
        {service: 'product', wlp: 'core', restart: false},
    ]
}