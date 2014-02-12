RSpec.configure do |config|
  config.color_enabled = true
  config.formatter = :documentation
end

class IO
  alias_method :puts_orig, :puts
  def puts(*args)
    # Make puts write complete lines.
    # Ordinarily if the object does not have a trailing newline, puts will make a separate write call for the newline.
    # This causes major annoyance when multiple things are writing to the terminal at the same time, as something might get written before the newline.
    args.each do |obj|
      s = obj.to_s
      puts_orig(s[-1] == $/ ? s : s + $/)
    end
    puts_orig if args.size == 0
  end
end

class Requester
  require 'ostruct'

  def initialize(port)
    @port = port
  end
  def request(method, resource, params = {})
    sock = TCPSocket.new('127.0.0.1', @port)

    begin
      sock.write("#{method.to_s.upcase} #{resource} HTTP/1.1\r\n")

      sock.write("Host: 127.0.0.1\r\n")

      sleep params[:sleep_headers] if params[:sleep_headers]
      if params[:close_headers] then
        sock.close_write
      else
        if params[:headers] then
          params[:headers].each do |k,v|
            sock.write("#{k}: #{v}\r\n")
          end
        end

        body_len = params[:body] ? params[:body].bytesize : 0
        sock.write("Content-Length: #{body_len}\r\n")

        sock.write("Connection: close\r\n")
        sock.write("\r\n")

        if params[:body] then
          sock.write(params[:body][0, params[:body].size / 2])

          sleep params[:sleep_body] if params[:sleep_body]

          if params[:close_body] then
            sock.close_write
          else
            sock.write(params[:body][params[:body].size / 2, params[:body].size - params[:body].size / 2])
          end
        end
      end
    rescue Errno::EPIPE
    end


    response = OpenStruct.new
    begin
      while response[:state] != :body and line = sock.readline do
        line.sub(/\r?\n$/, '')
        if response[:state].nil? then
          response[:head] = line
          response[:proto], response[:code], response[:text] = response[:head].split(' ', 3)
          response[:code] = response[:code].to_i

          response[:headers] = {}
          response[:headers_lower] = {}

          response[:state] = :headers
        elsif response[:state] == :headers then
          if line == '' then
            response[:state] = :body
          else
            name, value = line.split(': ')
            response[:headers][name] = value
            response[:headers_lower][name.downcase] = value
          end
        end
      end
      if response[:state] == :body then
        if response[:headers_lower]['content-length'] then
          response[:body] = sock.read(response[:headers_lower]['content-length'].to_i)
        else
          response[:body] = sock.read
        end
      end
    rescue EOFError
    end

    sock.close

    response
  end
  alias_method :new, :request
end

class Server
  require 'net/http'
  require 'uri'

  attr_reader :thread
  attr_accessor :verbose

  def initialize(port)
    @port = port
  end

  def start
    @thread = Thread.new do
      Thread.current.abort_on_exception = true

      listener = TCPServer.new('127.0.0.1', @port)
      @clients = {}
      loop do
        socks = IO.select([listener] + @clients.keys)
        socks[0].each do |sock|
          if sock == listener then
            @clients[listener.accept] = {:buf => ''.force_encoding('ASCII-8BIT')}
          else
            begin
              client_read(sock)
              @clients.delete(sock) if sock.closed?
            rescue => e
              $stderr.puts "Exception: #{e} (#{e.class})\n#{e.backtrace.join("\n")}\n" unless e.is_a?(EOFError) or e.is_a?(Errno::ECONNRESET)

              sock.close unless sock.closed?
              @clients.delete(sock)
            end
          end
        end
      end
    end
    Timeout::timeout(5) do
      begin
        Net::HTTP.get_response(URI.parse("http://localhost:#{@port}"))
      rescue Errno::ECONNREFUSED
        sleep 0.1
        retry
      end
    end

    self
  end
  def stop
    @thread.kill
  end

  def client_read(sock)
    client = @clients[sock]

    client[:buf].concat sock.read_nonblock(4096)

    if client[:state].nil? then # waiting for request line
      split = client[:buf].split(/\r?\n/, 2)
      return if split.size == 1 # didn't split. no terminating \r\n found
      client[:request] = split[0]
      client[:buf] = split[1]

      client[:method], client[:resource], client[:proto] = client[:request].split(' ', 3)
      client[:path], params = client[:resource].split('?', 2)
      client[:params] = {}
      client[:params_lower] = {}
      if params then
        params.split('&').each do |param|
          name, value = param.split('=', 2)
          client[:params][name] = value
          client[:params_lower][name.downcase] = value
        end
      end

      # process request line

      client[:state] = :headers
    end

    if client[:state] == :headers
      split = client[:buf].split(/\r?\n\r?\n/, 2)
      return if split.size == 1 # didn't split. no empty line found
      headers_buf = split[0]
      client[:buf] = split[1]

      client[:headers] = {}
      client[:headers_lower] = {}
      headers_buf.split(/\r?\n/).each do |header_line|
        header, data = header_line.split(': ', 2)
        client[:headers][header] = data
        client[:headers_lower][header.downcase] = data
      end

      # process headers

      if client[:headers_lower]['content-length'] then
        client[:state] = :body
      else
        client[:state] = :finished
      end
    end

    if client[:state] == :body then
      if client[:params_lower]['close_client_body'] then
        sock.close
        return
      end

      body_size = client[:headers_lower]['content-length'].to_i

      return if client[:buf].size < body_size # not enough body received

      client[:body] = client[:buf][0, body_size]

      # process body

      client[:state] = :finished
    end



    if client[:state] == :finished then
      # Generate response

      if client[:params_lower]['sleep_status'] then
        # sleep before status line
        sleep client[:params_lower]['sleep_status'].to_f
      end

      status = client[:params_lower]['respond_status'] || "200"
      status_text = client[:params_lower]['respond_status_text'] || 'OK'
      sock.write("HTTP/1.1 #{status} #{status_text}\r\n")
      sock.write("Connection: close\r\n")

      if client[:params_lower]['sleep_headers'] then
        # sleep in the middle of headers
        sleep client[:params_lower]['sleep_headers'].to_f
      end
      if client[:params_lower]['close_headers'] then
        sock.close
        return
      end

      if client[:path].match(%r#^/echo/?(.*)#) then
        response = $1
      else
        response = ''
      end

      sock.write("Content-length: #{response.bytesize}\r\n")
      sock.write("Content-type: text/plain\r\n")

      if client[:params_lower]['sleep'] then
        # sleep before sending body
        sleep client[:params_lower]['sleep'].to_f
      end

      sock.write("\r\n")

      # send half the body
      sock.write(response[0, response.size / 2]) if response.size > 0

      if client[:params_lower]['sleep_body'] then
        # sleep in the middle of the body
        sleep client[:params_lower]['sleep_body'].to_f
      end
      if client[:params_lower]['close_body'] then
        sock.close
        return
      end

      # send the rest of the body
      sock.write(response[response.size / 2, response.size - response.size / 2]) if response.size > 0

      if client[:params_lower]['sleep_close'] then
        # sleep before close
        sleep client[:params_lower]['sleep_close'].to_f
      end
    end
  end
end

class Haproxy
  def self.finalizer(pid)
    proc do
      Process.kill('TERM', pid)
    end
  end

  def initialize(path = ENV['HAPROXY'], cfg_path = ENV['HAPROXY_CFG'])
    @path = path
    @cfg_path = cfg_path
  end
  def start(wait_port = nil)
    @pid = Process.spawn(@path, '-f', @cfg_path, '-db')
    @finalizer = self.class.finalizer(@pid)
    ObjectSpace.define_finalizer(self, @finalizer)

    wait_responsive(wait_port) if wait_port

    self
  end
  def wait_responsive(port)
    # waits for it to start responding
    Timeout::timeout(5) do
      begin
        Net::HTTP.get_response(URI.parse("http://localhost:#{port}"))
      rescue Errno::ECONNREFUSED
        sleep 0.1
        retry
      end
    end
  end
  def stop
    @finalizer.call
    ObjectSpace.undefine_finalizer(self)

    nil
  end
end

class Haproxy::LogDaemon
  def initialize(port)
    @port = port
  end
  def start
    @thread = Thread.new do
      socket = UDPSocket.new
      socket.bind(nil, @port)
      while msg = socket.recvfrom(4096)
        text = msg.first.chomp
        text.sub!(/^.*?\d\d:\d\d:\d\d /, '')
        puts text + "\n"
      end
    end

    self
  end
  def stop
    @thread.kill

    nil
  end
end
