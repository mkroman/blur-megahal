# encoding: utf-8

require 'uri'

Script :megahal do
  Greetings = %w[
    hej hey yo goddag goddur værhilset hils
    dav davs farvel hvaså sup wsup velkommen
    hallo godmorgen godaften hejsa godnat
    godeftermiddag god_dag
  ].freeze
  ColorRegexp = /[\x02\x16\x0f\x1f\x12]|\x03(\d\d?(,\d\d?)?)?/.freeze

  # Requirements before MegaHAL wil attempt to learn anything from a message.
  MessageLength = 12

  # A MegaHAL process wrapper. 
  class MegaHAL < EM::Connection
    Executable = File.join File.dirname(__FILE__), '/megahal/megahal -pwb'
    CommandsRegexp = /QUIT|EXIT|SAVE|DELAY|SPEECH|VOICES?|BRAIN|HELP|QUIET/i.freeze
    CommandsFilter = Regexp.compile(/#+#{Regexp.union CommandsRegexp}/).freeze

    # Open the process without blocking, and attach it to the EventMachine loop.
    # This redirects stderr of the main thread so the child will inherit it.
    # 
    # It's one of the many design-flaws of EventMachine.
    # 
    # @yield [MegaHAL] The MegaHAL connection instance. Use this as a reference
    # instead of the return value.
    # @return nil
    def self.start
      null   = File.open File::NULL, 'w'
      stderr = $stderr

      EM.schedule do
        $stderr.reopen null
        process = EM.popen Executable, MegaHAL
        $stderr.reopen stderr

        yield process if block_given?
      end
    end

    # Set up MegaHAL internals.
    def post_init
      puts "Connected to MegaHAL!"

      @buffer = ""
      @call_stack = []
      @message_counter = 0
    end

    # Pop a callback off of the stack and yield it, and do this for every new
    # line received by MegaHAL.
    #
    # @api private
    def receive_data data
      @buffer << data

      @buffer.each_line do |line|
        @buffer.slice! 0, line.length

        block = @call_stack.pop
        block.(line.strip) if block
      end
    end

    # Tell MegaHAL something.
    #
    # @yield [String] The MegaHAL response.
    def tell! message, &block
      message = sanitize_message message.to_s
      return if message.empty?

      send_data "#{message}\n\n"

      # Save the database if we have exceeded the limit.
      if (@message_counter += 1) > 30
        if @call_stack.empty?
          save

          @message_counter = 0
        end
      end

      if block_given?
        @call_stack << block
      end
    end

    # Tell MegaHAL to save the database.
    def save
      puts "(MegaHAL) Saving brain"

      send_data "#save\n\n"
    end

    # Gracefully quit MegaHAL.
    def quit
      send_data "#quit\n\n"

      close_connection_after_writing
    end

  private
    # Sanitize the input message so that it won't execute any commands.
    def sanitize_message message
      message.gsub(CommandsFilter, '').strip
    end
  end

  # Make MegaHAL quit gracefully when the script is unloaded.
  def unloaded
    @megahal.quit
  end

  # Open the MegaHAL process.
  def loaded
    MegaHAL.start do |megahal|
      @megahal = megahal
    end
    
    # Nicknames are kept in memory for faster access.
    # This doesn't work that well with multiple channels.
    cache[:names] ||= []
  end

  # Update the cached names list.
  def channel_who_reply channel
    cache[:names].concat channel.users.map(&:nick)
    cache[:names].uniq!
  end

  # A user said something, was it for us?
  def message user, channel, line
    return if contains_uris? line

    my_name = channel.network.options[:nickname]

    if line.to_s =~ /^#{Regexp.escape my_name}\W (.+)/i
      @megahal.tell! strip_color_from $1.to_s do |response|
        channel.say "#{user.nick}: #{response}"
      end
    else
      passively_learn! line.to_s
    end
  end

  # A user entered the channel. Greet them with a random message.
  def user_entered channel, user
    cache[:names] << user.nick unless cache[:names].include? user.nick

    @megahal.tell! random_greeting do |response|
      channel.say "#{user.nick}: #{response}"
    end
  end

  # A user left the channel.
  # Remove the users name from the name list.
  def user_left channel, user
    cache[:names].delete user.nick
  end

  # A user disconnected.
  def user_quit channel, user
    cache[:names].delete user.nick
  end

  # Return a random greeting.
  #
  # @api private
  def random_greeting
    Greetings.sample
  end

  # Return true if the line contains any URLs.
  def contains_uris? string
    not URI.extract(string, /https?/i).empty?
  end

  # Passively learn something from a message.
  def passively_learn! message
    # Strip the color from the message.
    message = strip_color_from message
    # A regexp union containing all nicknames.
    name_regexp = Regexp.union cache[:names] || []

    # Skip the message if it doesn't meet the requirements.
    if message.length < MessageLength
      puts "(MegaHAL) Skipped message #{message.inspect}"
      return
    end

    if message =~ /^#{name_regexp}\W (.+)/
      # This was a message prefixed with a used nickname, strip the nickname
      # part and send the message to MegaHAL.
      puts "(MegaHAL) Passively learning: #{$1.inspect}"

      @megahal.tell! $1
    elsif message =~ /(.*?)[\W\s]+#{name_regexp}$/
      # This was a message suffixed with a used nickname, strip the nickname
      # part and send the message to MegaHAL.
      puts "(MegaHAL) Passively learning: #{$1.inspect}"

      @megahal.tell! $1
    elsif message =~ /^[!\.]/
      # Ignore the message.
    else
      # Send the message to MegaHAL.
      @megahal.tell! message
    end
  end

  # Strip the mIRC control-colors from a string.
  def strip_color_from message
    message.gsub ColorRegexp, ''
  end
end
