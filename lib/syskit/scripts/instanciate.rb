require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

Roby.app.using_plugins 'orocos'
available_annotations = Orocos::RobyPlugin::Graphviz.available_annotations

compute_policies    = true
compute_deployments = true
remove_compositions = false
remove_loggers      = true
validate_network    = true
test = false
annotations = Set.new
default_annotations = ["connection_policy", "task_info"]
display_timepoints = false
pprof_file_path = nil
rprof_file_path = nil

parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate [options] deployment [additional services]
   'deployment' is either the name of a deployment in config/deployments,
    or a file that should be loaded to get the desired deployment
    'additional services', if given, refers to services defined with
    'define' that should be added
    "

    opt.on('--annotate=LIST', Array, "comma-separated list of annotations that should be added to the output (defaults to #{default_annotations.to_a.join(",")}). Available annotations: #{available_annotations.to_a.sort.join(", ")}") do |ann|
        ann.each do |name|
            if !available_annotations.include?(name)
                STDERR.puts "#{name} is not a known annotation. Known annotations are: #{available_annotations.join(", ")}"
                exit 1
            end
        end

        annotations |= ann.to_set
    end

    opt.on('--no-policies', "don't compute the connection policies") do
        compute_policies = false
    end
    opt.on('--no-deployments', "don't deploy") do
        compute_deployments = false
    end
    opt.on("--[no-]loggers", "remove all loggers from the generated data flow graph") do |value|
        remove_loggers = !value
    end
    opt.on("--no-compositions", "remove all compositions from the generated data flow graph") do
        remove_compositions = true
    end
    opt.on("--dont-validate", "do not validate the generate system network") do
        validate_network = false
    end
    opt.on("--timepoints") do
        display_timepoints = true
    end
    opt.on("--rprof=FILE", String, "run the deployment algorithm under ruby-prof, and generates a kcachegrind-compatible output to FILE") do |path|
        display_timepoints = true
        if path
            rprof_file_path = path
        end
    end
    opt.on("--pprof=FILE", String, "run the deployment algorithm under google perftools, and generates the raw profiling information to FILE") do |path|
        display_timepoints = true
        if path
            pprof_file_path = path
        end
    end
    opt.on('--test', 'test mode: instanciates everything defined in the given file') do
        test = true
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end

if annotations.empty?
    annotations = default_annotations
end

if test
    test_file = remaining.shift
    test_setup = YAML.load(File.read(test_file))

    config = test_setup.delete('configuration') || %w{--no-loggers --no-compositions -osvg}

    default_deployment = test_setup.delete('default_deployment') || '-'
    default_robot = test_setup.delete('default_robot')
    default_def = { 'deployment' => default_deployment, 'robot' => default_robot, 'services' => [] }

    output_option, config = config.partition { |s| s =~ /^-o(\w+)$/ }
    output_option = output_option.first
    if !output_option
        output_option = "-osvg"
    end

    simple_tests = test_setup.delete('simple_tests') || []
    simple_tests.each do |name|
        test_setup[name] = [name]
    end

    test_setup.each do |test_name, test_def|
        if test_def.respond_to?(:to_ary)
            test_def = { 'services' => test_def }
        elsif test_def.respond_to?(:to_str)
            test_def = { 'services' => [test_def] }
        end

        test_def = default_def.merge(test_def)

        dirname = "instanciate"
        if test_def['robot']
            dirname << "-#{test_def['robot']}"
        end
        outdir = File.join(File.dirname(test_file), 'results', dirname)
        outdir = File.expand_path(outdir)
        FileUtils.mkdir_p(outdir)

        cmdline = []
        cmdline.concat(config)
        cmdline << output_option + ":#{File.join(outdir, test_name)}"
        if test_def['robot']
            cmdline << "-r#{test_def['robot']}"
        end
        cmdline << test_def['deployment']
        cmdline.concat(test_def['services'])

        txtlog = File.join(outdir, "#{test_name}-out.txt")
        shellcmd = "#{$0} '#{cmdline.join("' '")}' >> #{txtlog} 2>&1"
        File.open(txtlog, 'w') do |io|
            io.puts test_name
            io.puts shellcmd
            io.puts
        end

        STDERR.print "running test #{test_name}... "
        `#{shellcmd}`
        if $?.exitstatus != 0
            if $?.exitstatus == 2
                STDERR.puts "deployment successful, but dot failed to generate the resulting network"
            else
                STDERR.puts "failed"
            end
        else
            STDERR.puts "success"
        end
    end
    exit(0)

else
    passes = [[remaining.shift, []]]
    pass = 0
    while name = remaining.shift
        if name == "/"
            pass += 1
            passes[pass] = [remaining.shift, []]
        else
            passes[pass][1] << name
        end
    end
end

require 'roby/standalone'

# Generate a default name if the output file name has not been given
output_type, output_file = Scripts.output_type, Scripts.output_file
if output_type != 'txt' && !output_file
    output_file =
        if base_name = (Scripts.robot_name || Scripts.robot_type)
            base_name
        elsif deployment_file != '-'
            deployment_file
        else
            "instanciate"
        end
end

if rprof_file_path
    require 'ruby-prof'
elsif pprof_file_path
    require 'perftools'
end

# We don't need the process server, win some startup time
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true
Roby.app.single
Scripts.tic
error = Scripts.run do
    GC.start

    passes.each do |deployment_file, additional_services|
        if deployment_file != '-'
            Roby.app.load_orocos_deployment(deployment_file)
        end
        additional_services.each do |service_name|
            service_name = Scripts.resolve_service_name(service_name)
            Roby.app.orocos_engine.add service_name
        end
        Scripts.toc_tic "initialized in %.3f seconds"

        if rprof_file_path
            RubyProf.resume
        elsif pprof_file_path && !PerfTools::CpuProfiler.running?
            PerfTools::CpuProfiler.start(pprof_file_path)
        end
        Roby.app.orocos_engine.
            resolve(:export_plan_on_error => false,
                :compute_policies => compute_policies,
                :compute_deployments => compute_deployments,
                :validate_network => validate_network)
        if display_timepoints
            pp Roby.app.orocos_engine.format_timepoints
        end
        if rprof_file_path
            RubyProf.pause
        end
        Scripts.toc_tic "computed deployment in %.3f seconds"
    end
end

if rprof_file_path
    result = RubyProf.stop
    printer = RubyProf::CallTreePrinter.new(result)
    printer.print(File.open(profile_file_path, 'w'), 0)
elsif pprof_file_path
    PerfTools::CpuProfiler.stop
end

if error
    exit(1)
end

excluded_tasks      = ValueSet.new
if remove_loggers
    excluded_tasks << Orocos::RobyPlugin::Logger::Logger
end

hierarchy_file = "#{output_file}-hierarchy.#{output_type}"
dataflow_file = "#{output_file}-dataflow.#{output_type}"

case output_type
when "txt"
    pp Roby.app.orocos_engine
when "dot"
    File.open(hierarchy_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_engine.to_dot_hierarchy
    end
    File.open(dataflow_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks, annotations)
    end
when "x11"
    output_file  = nil
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks, annotations)
        io.flush
        `dot -Tx11 #{io.path}`
        if $?.exitstatus != 0
            STDERR.puts "dot failed to display the network"
        end
    end

when "svg", "png"
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks, annotations)
        io.flush

        File.open(dataflow_file, 'w') do |output_io|
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
            if $?.exitstatus != 0
                STDERR.puts "dot failed to generate the network"
                exit(2)
            end
        end
    end
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_hierarchy
        io.flush

        File.open(hierarchy_file, 'w') do |output_io|
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
            if $?.exitstatus != 0
                STDERR.puts "dot failed to generate the network"
                exit(2)
            end
        end
    end
end

if output_file
    STDERR.puts "output task hierarchy in #{hierarchy_file}"
    STDERR.puts "output dataflow in #{dataflow_file}"
end

