require 'roby'
require 'syskit/roby_app/process_server'

require 'optparse'

options = Hash[host: 'localhost']
parser = OptionParser.new do |opt|
    opt.on '--fd=FD', Integer, "the socket that should be used as TCP server" do |fd|
        options[:fd] = fd
    end
    opt.on '--log-dir=DIR', String, 'the directory that should be used for logs' do |dir|
        Roby.app.log_dir = dir
    end
    opt.on('--debug', 'turn on debug mode') do
        Orocos.logger.level = Logger::DEBUG
    end
end

server_port = Orocos::RemoteProcesses::DEFAULT_PORT
Roby::Application.host_options(parser, options)
parser.parse(ARGV)

Orocos::CORBA.name_service.ip = options[:host]
Orocos.disable_sigchld_handler = true
Orocos.initialize
server = Syskit::RobyApp::ProcessServer.new(Roby.app, port: server_port)
server.open(fd: options[:fd])
server.listen

