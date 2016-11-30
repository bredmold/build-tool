# silver-dollar
Update a bunch of projects from Git and build them

## About

Build the world! This script has a lot of options and makes some assumptions about your build environment.
To start with, type `silver-dollar -h` to get a current list of command-line options.

The biggest assumption is that all of your git clones are siblings of one another in the filesystem.

If you keep your clones in `~/my/projects` then type `silver-dollar -d ~/my/projects -r`. This will generate a report
of your local projects and their associated branch names.

To run a full build, try `silver-dollar -d ~/my/projects -a`. This will run a build that will not fail if you're missing
projects locally.

Please be kind in evaluating the code. I used this project to learn Ruby.

## Future Plans

Possible future development directions, in no particular order.

* Gradle support
* Shared feature branches
  * Acts like a 'master' branch, but the tool can automatically merge from a basis branch
  * Automatically push?
* Basis branch for rebase can be a list, or can be project-based
* Configuration file with similar style to Gradle or Chef
