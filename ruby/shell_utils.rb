module ShellTools
    # Fail the program if the shell command failed
    def verify_status(status, operation)
        if 0 != status.exitstatus
            puts "#{project}: #{operation} failed with status #{status.exitstatus}\n"
            exit status.exitstatus
        end
    end

    # Report to stdout if the shell command failed
    def report_status(status, operation)
        if 0 != status.exitstatus
            puts "#{project}: #{operation} failed with status #{status.exitstatus}\n"
        end
        0 == status.exitstatus
    end
end