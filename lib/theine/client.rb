require 'drb/drb'
require 'readline'
require_relative './config'

class IOUndumpedProxy
  include DRb::DRbUndumped

  def initialize(obj)
    @obj = obj
  end

  def completion_proc=(val)
    if @obj.respond_to? :completion_proc=
      @obj.completion_proc = val
    end
  end

  def completion_proc
    @obj.completion_proc if @obj.respond_to? :completion_proc
  end

  def readline(prompt)
    if ::Readline == @obj
      @obj.readline(prompt, true)
    elsif @obj.method(:readline).arity == 1
      @obj.readline(prompt)
    else
      $stdout.print prompt
      @obj.readline
    end
  end

  def readline_arity
    method(:readline).arity
  rescue NameError
    0
  end

  def gets(*args)
    @obj.gets(*args)
  end

  def puts(*lines)
    @obj.puts(*lines)
  end

  def print(*objs)
    @obj.print(*objs)
  end

  def write(data)
    @obj.write data
  end

  def <<(data)
    @obj << data
    self
  end

  def flush
    @obj.flush
  end

  # Some versions of Pry expect $stdout or its output objects to respond to
  # this message.
  def tty?
    false
  end
end

module Theine
  class Client
    def self.start
      new
    end

    attr_reader :config

    def initialize
      @config = ConfigReader.new(Dir.pwd)
      reset_argv!
      trap_signals
      begin
        connect_worker
        redirect_io
        run_command
      ensure
        stop
      end
    end

    def stop(sleep_for = 0.1)
      begin
        puts "stopping"
        if @worker
          #@worker.stop!
          @balancer.stop_worker(@port)
          #%x[kill -2 #{@worker.pid}] # TODO: if client was term-ed, term worker (maybe term)
          sleep(sleep_for) if sleep_for > 0 # to finish receiving IO
        end
      rescue DRb::DRbConnError
      end
      exit(0)
    end

  private
    def run_command
      case @argv[0]
      when "rake"
        @argv.shift
        @worker.command_rake(@argv)
      when "rspec"
        @argv.shift
        @worker.command_rspec(@argv)
      else
        if ["c", "console"].include?(@argv[0])
          load_pry_history
        end
        @worker.command_rails(@argv)
      end
    rescue DRb::DRbConnError
      $stderr.puts "\nTheine closed the connection."
    end

    def load_pry_history
      history_file = File.expand_path("~/.pry_history")
      if File.exist?(history_file)
        File.readlines(history_file).pop(100).each do |line|
          Readline::HISTORY << line[0, line.size-1]
        end
      end
    end

    def reset_argv!
      @argv = ARGV.dup
      ARGV.clear
    end

    def trap_signals
      trap('INT') { exit(0) }
      trap('TERM') { exit(0) }
    end

    def redirect_io
      # Need to be careful that these don't get garbage collected
      $stdin_undumped = @worker.stdin = IOUndumpedProxy.new(Readline)
      $stdout_undumped = @worker.stdout = IOUndumpedProxy.new($stdout)
      $stderr_undumped = @worker.stderr = IOUndumpedProxy.new($stderr)
    end

    def connect_balancer
      @balancer = wait_until_result("Cannot connect to theine server. Waiting") do
        object = DRbObject.new_with_uri("druby://localhost:#{config.base_port}")
        object.respond_to?(:get_port) # test if connected
        object
      end
    end

    def connect_worker
      connect_balancer
      @port = wait_until_result("Waiting for Theine worker...") do
        @balancer.get_port
      end
      @worker = DRbObject.new_with_uri("druby://localhost:#{@port}")
    end

    WaitResultNoResultError = Class.new(StandardError)
    def wait_until_result(wait_message)
      result = nil
      dots = 0
      begin
        result = yield
        raise WaitResultNoResultError unless result
      rescue DRb::DRbConnError, WaitResultNoResultError
        print dots == 0 ? wait_message : "."
        dots += 1
        sleep 0.5
        retry
      end
      print "\n" if dots > 0
      result
    end
  end
end

DRb.start_service
Theine::Client.start
