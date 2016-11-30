# Provide a collection of named timer objects
class Stopwatch
    def initialize
        @timers = {}
        @format = "%-17s %s\n"
    end

    def start(timer)
        @timers[timer] = {
            start: Time.now,
            stop: nil,
        }
    end

    def stop(timer)
        @timers[timer][:stop] = Time.now
    end

    def report
        printf(@format, 'Timer', 'Time')
        printf(@format, '=====', '====')
        @timers.each do |timer, instance|
            timer_line(timer, instance)
        end
    end

    def get(timer)
        instance = @timers[timer]
        if nil == instance[:stop]
            self.stop(timer)
        end
        instance[:stop] - instance[:start]
    end

    def format(timer)
        elapsed = self.get(timer)
        minutes = (elapsed / 60).floor
        seconds = elapsed - (minutes * 60)
        sprintf("%02d:%02d", minutes, seconds)
    end

    private

    def timer_line(timer, instance)
        printf(@format, timer, self.format(timer))
    end
end
