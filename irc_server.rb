require "./server"
require "./message"
require "resolv"
require "hashie"


CHANNEL_NICK_MODES = ["qaohv","~&@%+"]
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

class BaseUser
  attr_accessor :nick, :username, :hostname, :real_name
  def full_nickname
    "#{@nick}!#{@username}@#{@hostname}"
  end
end

class ChannelUser
  attr_accessor :user, :modes
  def initialize user, modes
    @user = user
    @modes = modes
  end
  def prefix
    if modes.empty?
      ""
    else
      CHANNEL_NICK_MODES[1][CHANNEL_NICK_MODES[0].index(modes.first)]
    end
  end
  def prefixed_name
    "#{prefix}#{user.nick}"
  end
end

class CommandHandler
  attr_accessor :command, :block
  def initialize command, &block
    @command = command
    @block = block
  end
end

class BaseChannel
  attr_accessor :name, :topic, :mode, :owner, :users, :owner_channel_user
  def initialize owner, name
    @owner = owner
    @name = name
    @topic = ""
    @users = [] 
    @command_handlers = []
    @command_help = []
    @text_handlers = []
    @owner_present = false
  end
  def get_command_help include_hidden=false
    include_hidden ? @command_help : (@command_help.select { |cs, hs| !hs[2] })
  end
  def join_owner owner
    @owner_present = true
    owner.send_message owner.full_nickname, "JOIN", [name]
    channel_user = ChannelUser.new(owner, ["q","o"])
    @users << channel_user
    @owner_channel_user = channel_user
    send_topic
    send_user_list
  end

  def send_topic
    owner.send_numeric 332, name, topic
  end

  def send_user_list
    users.each_slice(5).each do |uset| 
      owner.send_numeric 353, "=", name, uset.map(&:prefixed_name).join(" ")
    end
    owner.send_numeric 366, name, "End of NAMES list"
  end


  def join_user user
    owner.send_message user.full_nickname, "JOIN", [name] if @owner_present
    add_user user
  end

  def set_mode_to_user setter, target, add_mode, remove_mode = []
    target.modes = target.modes - remove_mode + add_mode
    remove_mode.each do |m|
      owner.send_message setter.full_nickname, "MODE", ["-#{m}", target.user.nick] if @owner_present
    end
    add_mode.each do |m|
      owner.send_message setter.full_nickname, "MODE", ["+#{m}", target.user.nick] if @owner_present
    end
  end

  def user_for_user user
    @users.detect { |u| u.user == user }
  end

  def kick_user kicker, target, reason
    owner.send_message kicker.full_nickname, "KICK", [name, target.nick, reason] if @owner_present
    remove_user target
  end

  def add_user user, modes = []
    chuser = ChannelUser.new(user, modes) unless user_for_user user
    @users << chuser
    chuser
  end

  def remove_user user
    u = user_for_user user
    @users.delete u if u
  end

  def msg user, message
    owner.send_message user.full_nickname, "PRIVMSG", [name, message]
  end

  def notice user, message
    owner.send_message user.full_nickname, "NOTICE", [name, message]
  end
  def ctcp user, ctcp_type, message
    msg user, "\x01#{ctcp_type} #{message}\x01"
  end
  def ctcp_reply user, ctcp_type, message
    notice user, "\x01#{ctcp_type} #{message}\x01"
  end
  def action user, message
    ctcp user, "ACTION", message
  end
  def on_command help, *command, &block
    command.each do |c|
      @command_handlers << CommandHandler.new(c.downcase, &block)
    end
    @command_help << [command, help]
  end
  def on_text &block
    @text_handlers << block
  end
  def handle_command command, args
    begin
      @command_handlers.select{|handler| handler.command.downcase == command.downcase}.each {|handler| handler.block.call(self, owner, args)}
    rescue => e
      msg owner.control_user, "ERROR! #{e.message}"      
    end
  end
  def handle_text text
    begin
      @text_handlers.each {|handler| handler.call(self, owner, text)}
    rescue => e
      msg owner.control_user, "ERROR! #{e.message}"      
    end
  end
end

class ControlChannel < BaseChannel
  def initialize owner
    @owner = owner
    @name = "&control"
    @topic = "Command Center"
    @users = []
    @users << ChannelUser.new(owner.control_user, ["a","o"])
    @command_handlers = []
    @command_help = []
    @text_handlers = []
  end
end

class ControlUser < BaseUser
  def initialize owner
    @owner = owner
    @nick = "さわちゃん"
    @username = "sawa"
    @hostname = "sawako.jp"
    @real_name = "さわちゃん"
  end
end


class VirtualUser < BaseUser
end

class VirtualChannel < BaseChannel

  def initialize owner, name, topic
    @owner = owner
    @name = name
    @topic = topic
    @users = []
    @users << ChannelUser.new(owner.control_user, ["a","o"])
    @text_handlers = []
    @command_help = []
    @command_handlers = []
  end

end

class Owner < BaseUser
  attr_accessor :server, :socket, :server_name, :ip, :channels, :control_channel, :control_user, :users, :control_controller, :data, :should_die, :die_reason
  def initialize server, socket, control_factory
    @data = ::Hashie::Mash.new
    @server = server
    @socket = socket
    @nick = nil
    @username = nil
    @server_name = nil
    @real_name = nil
    @control_controller = control_factory.new self
    control_controller.assign_handlers
    @ip = socket.peeraddr.last
    @hostname = "twitter.com" # Resolv.getname @ip
    @control_user = ControlUser.new self
    @channels = []
    @users = []
    @should_die = false
    @die_reason = false
    @users << self
    @users << @control_user
  end
  def destroy reason
    @should_die = true
    @die_reason = reason
  end
  def control_msg message
    control_channel.msg control_user, message
  end
  def serv_notice service, message
    send_message "#{service}!#{service.downcase}@services.nubee.com", "NOTICE", [nick, message]
  end
  def set_user_params params
    @username = params[0] || nick.downcase
    @server_name = params[2]
    @real_name = params[3]
  end
  def send message
    server.enqueue self, message
  end
  def send_message prefix, command, params = []
    send IRCMessage.new(prefix,command,params).to_s
  end
  def msg from_user, message
    send_message from_user.full_nickname, "PRIVMSG", [nick, message]
  end
  def send_numeric numeric, *args
    send_message server.name, "%03d" % numeric, [nick] + args
  end
  def create_control_channel
    @control_channel = ControlChannel.new self
    @channels << control_channel
    @control_channel.join_owner self
    control_controller.setup_control_channel control_channel
  end
  def create_channel name, topic, &block
    channel = VirtualChannel.new self, name, topic
    @channels << channel
    block.call channel
  end
  def get_channel_by_name channel_name
    channels.detect { |c| c.name.downcase == channel_name.downcase }
  end
  def get_user_by_nick user_nick
    users.detect { |u| u.nick.downcase == user_nick.downcase }
  end

end

class OutgoingTask
  attr_accessor :owner, :message
  def initialize owner, message
    @owner = owner
    @message = message
  end
end

class Server

  def initialize control_factory
    @control_factory = control_factory
    @srv = MulticlientTCPServer.new( 9198, 1, true )
    @owners = []
    @outgoing_tasks = []
    puts "Server is running"
  end

  def get_owner_from_socket socket
    @owners.detect { |u| u.socket == socket } || begin
      puts "NEW USER"
      owner = Owner.new self, socket, @control_factory
      @owners << owner
      owner
    end
  end

  def enqueue owner, message
    @outgoing_tasks << OutgoingTask.new(owner, message)
  end

  def flush_outgoing_tasks
    unless @outgoing_tasks.empty?
      @outgoing_tasks.each do |task|
        if !task.owner.should_die
          begin
            task.owner.socket.write task.message
            puts "sending #{task.message} to #{task.owner.full_nickname}"
          rescue => e
            puts "COULD NOT SEND TO OWNER, GOING TO KILL THEM"
            puts e.inspect
            task.owner.destroy "Could not send message due to: #{e.inspect}"
            @owners.delete task.owner
          end
        end
      end
      @outgoing_tasks.clear
    end
  end

  def handle_message owner, message
    puts message
    msg = IRCMessage.parse message
    case msg.command.upcase
    when "NICK"
      owner.nick = msg.params.first
      puts "Set user nick to #{owner.nick}"
    when "USER"
      owner.set_user_params msg.params
      puts "User connected: #{owner.full_nickname}"
      puts "Real name: #{owner.real_name}"
      send_welcome_package owner
      owner.create_control_channel
    when "WHOIS"
      user = owner.users.detect{|u| u.nick.downcase == msg.params.first.downcase}
      if user == owner.control_user
        send_numeric owner, 311, user.nick, user.username, user.hostname, "*", user.real_name
        send_numeric owner, 312, user.nick, owner.server.name, "Server Info"
        send_numeric owner, 318, user.nick, "End of WHOIS list"
      else
        owner.control_controller.handle_irc_command msg.command, msg.prefix, msg.params
      end
    when "PRIVMSG"
      target = msg.params.first
      if ['nickserv','chanserv'].include? target.downcase
        command, sep, args = msg.params[1].partition(" ")
        owner.control_controller.handle_serv_command command.downcase, target.downcase, args
      elsif ['&','#'].include?(target[0])
        channel = owner.get_channel_by_name target
        if channel
          channel.handle_text msg.params[1]
          command, sep, args = msg.params[1].partition(" ")
          channel.handle_command command.downcase, args
        else
          send_numeric owner, 404, target, "Cannot send to channel"
        end
      else
        command, sep, args = msg.params[1].partition(" ")
        owner.control_controller.handle_pm_command command.downcase, target, args
      end
    end    
  end

  def run
    loop do
      sock = @srv.get_socket do |s, reason|
        owner = get_owner_from_socket s
        owner.destroy reason
        @owners.delete owner
      end

      if sock
        begin
          message = sock.gets( "\r\n" )
          owner = get_owner_from_socket sock
          handle_message owner, message
        rescue => e
          owner = get_owner_from_socket sock
          puts "BIG ERROR: #{e.inspect}"
          puts e.backtrace
          owner.destroy e.inspect
          @owners.delete owner
        end
      end
      flush_outgoing_tasks
    end
  end

  def send_message owner, prefix, command, params = []
    enqueue owner, IRCMessage.new(prefix,command,params).to_s
  end

  def name
    "nubee"
  end

  def version
    "0.01"
  end

  def created_at
    "now"
  end

  def send_numeric owner, numeric, *args
    send_message owner, name, "%03d" % numeric, [owner.nick] + args
  end

  def send_welcome_package owner
    send_numeric owner, 1, "Welcome to the Internet Relay Network #{owner.full_nickname}"
    send_numeric owner, 2, "Your host is #{name}, running version #{version}"
    send_numeric owner, 3, "This server was created #{created_at}"
    send_numeric owner, 4, "#{name}", "#{version}"
    send_numeric owner, 5, "PREFIX=(#{CHANNEL_NICK_MODES[0]})#{CHANNEL_NICK_MODES[1]}", 'CHANTYPES=#&', 'CHANMODES=be,k,l,imnpstr'
    send_numeric owner, 375, "- #{name} Message of the day - "
    send_numeric owner, 372, "- Yo!"
    send_numeric owner, 376, "End of MOTD command"

  end
end