module Orocos
    module RobyPlugin
        class SystemModel
            include CompositionModel

            attribute(:configuration) { Hash.new }

            def initialize
                @system = self
            end

            if method(:const_defined?).arity == 1 # probably Ruby 1.8
            def has_interface?(name)
                Orocos::RobyPlugin::Interfaces.const_defined?(name.camelcase(true))
            end
            def has_device_driver?(name)
                Orocos::RobyPlugin::DeviceDrivers.const_defined?(name.camelcase(true))
            end
            def has_composition?(name)
                Orocos::RobyPlugin::Compositions.const_defined?(name.camelcase(true))
            end
            else
            def has_interface?(name)
                Orocos::RobyPlugin::Interfaces.const_defined?(name.camelcase(true), false)
            end
            def has_device_driver?(name)
                Orocos::RobyPlugin::DeviceDrivers.const_defined?(name.camelcase(true), false)
            end
            def has_composition?(name)
                Orocos::RobyPlugin::Compositions.const_defined?(name.camelcase(true), false)
            end
            end

            def register_interface(model)
                Orocos::RobyPlugin::Interfaces.const_set(model.name.camelcase(true), model)
            end

            def register_device_driver(model)
                Orocos::RobyPlugin::DeviceDrivers.const_set(model.name.camelcase(true), model)
            end
            def register_composition(model)
                Orocos::RobyPlugin::Compositions.const_set(model.name.camelcase(true), model)
            end
            def each_composition(&block)
                Orocos::RobyPlugin::Compositions.constants.
                    map { |name| Orocos::RobyPlugin::Compositions.const_get(name) }.
                    find_all { |model| model.kind_of?(Class) && model < Composition }.
                    each(&block)
            end

            def import_types_from(*names)
                Roby.app.main_orogen_project.import_types_from(*names)
            end
            def load_system_model(name)
                Roby.app.load_system_model(name)
            end
            def using_task_library(*names)
                names.each do |n|
                    Roby.app.load_orogen_project(n)
                end
            end

            def interface(*args, &block)
                data_source_type(*args, &block)
            end

            def data_source_type(name, options = Hash.new, &block)
                options = Kernel.validate_options options,
                    :child_of => DataSource,
                    :interface    => nil

                const_name = name.camelcase(true)
                if has_interface?(name)
                    raise ArgumentError, "there is already a data source named #{name}"
                end

                parent_model = options[:child_of]
                if parent_model.respond_to?(:to_str)
                    parent_model = Orocos::RobyPlugin::Interfaces.const_get(parent_model.camelcase(true))
                end
                model = parent_model.new_submodel(name, :interface => options[:interface])
                if block_given?
                    model.interface(&block)
                end

                register_interface(model)
                model.instance_variable_set :@name, name
                model
            end

            def device_type(name, options = Hash.new)
                options, device_options = Kernel.filter_options options,
                    :provides => nil, :interface => nil

                const_name = name.camelcase(true)
                if has_device_driver?(name)
                    raise ArgumentError, "there is already a device type #{name}"
                end

                device_model = DeviceDriver.new_submodel(name, :interface => false)

                if parents = options[:provides]
                    parents = [*parents].map do |parent|
                        if parent.respond_to?(:to_str)
                            Orocos::RobyPlugin::Interfaces.const_get(parent.camelcase(true))
                        else
                            parent
                        end
                    end
                    parents.delete_if do |parent|
                        parents.any? { |p| p < parent }
                    end

                    bad_models = parents.find_all { |p| !(p < DataSource) }
                    if !bad_models.empty?
                        raise ArgumentError, "#{bad_models.map(&:name).join(", ")} are not interface models"
                    end

                elsif options[:provides].nil?
                    begin
                        parents = [Orocos::RobyPlugin::Interfaces.const_get(const_name)]
                    rescue NameError
                        parents = [self.data_source_type(name, :interface => options[:interface])]
                    end
                end

                if parents
                    parents.each { |p| device_model.include(p) }

                    interfaces = parents.find_all { |p| p.interface }
                    child_spec = device_model.create_orogen_interface
                    if !interfaces.empty?
                        first_interface = interfaces.shift
                        child_spec.subclasses first_interface.interface.name
                        interfaces.each do |p|
                            child_spec.implements p.interface.name
                            child_spec.merge_ports_from(p.interface)
                        end
                    end
                    device_model.instance_variable_set :@orogen_spec, child_spec
                end

                register_device_driver(device_model)
                device_model
            end

            def com_bus_type(name, options  = Hash.new)
                name = name.to_str

                if has_device_driver?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBusDriver.new_submodel(name, options)
                register_device_driver(model)
            end

            def composition(name, options = Hash.new, &block)
                subsystem(name, options, &block)
            end

            def subsystem(name, options = Hash.new, &block)
                name = name.to_s
                options = Kernel.validate_options options, :child_of => Composition, :register => true

                if options[:register] && has_composition?(name)
                    raise ArgumentError, "there is already a composition named '#{name}'"
                end

                new_model = options[:child_of].new_submodel(name, self)
                if block_given?
                    new_model.with_module(*RobyPlugin.constant_search_path, &block)
                end
                if options[:register]
                    register_composition(new_model)
                end
                new_model
            end

            def configure(task_model, &block)
                task = get(task_model)
                if task.configure_block
                    raise SpecError, "#{task_model} already has a configure block"
                end
                task.configure_block = block
                self
            end

            def pretty_print(pp)
                inheritance = Hash.new { |h, k| h[k] = Set.new }
                inheritance["Orocos::RobyPlugin::Component"] << "Orocos::RobyPlugin::Composition"

                pp.text "Compositions"; pp.breakable
                pp.text "------------"; pp.breakable
                pp.nest(2) do
                    pp.breakable
                    each_composition.sort_by(&:name).
                        each do |composition_model|
                            superclass = composition_model.parent_model
                            inheritance[superclass.name] << composition_model.name
                            composition_model.pretty_print(pp)
                            pp.breakable
                        end
                end

                pp.breakable
                pp.text "Models"; pp.breakable
                pp.text "------"; pp.breakable
                queue = [[0, "Orocos::RobyPlugin::Component"]]

                while !queue.empty?
                    indentation, model = queue.pop
                    pp.breakable
                    pp.text "#{" " * indentation}#{model}"

                    children = inheritance[model].
                        sort.reverse.
                        map { |m| [indentation + 2, m] }
                    queue.concat children
                end
            end

            def load(file)
                load_dsl_file(file, binding, true, Exception)
                self
            end

            def composition_to_dot(io, model)
                id = model.object_id

                inputs  = Hash.new { |h, k| h[k] = Array.new }
                outputs  = Hash.new { |h, k| h[k] = Array.new }
                model.connections.each do |(source, sink), mappings|
                    mappings.each do |(source_port, sink_port), policy|
                        outputs[source] << source_port
                        inputs[sink] << sink_port
                        io << "C#{id}#{source}:#{source_port} -> C#{id}#{sink}:#{sink_port};"
                    end
                end

                io << "subgraph cluster_#{id} {"
                # io << "  label=\"#{model.name}\";"
                # io << "  C#{id} [style=invisible];"
                model.each_child do |child_name, child_definition|
                    child_model = child_definition.models

                    label = "{"
                    task_label = child_model.map { |m| m.name }.join(',')
                    if !inputs[child_name].empty?
                        label << inputs[child_name].map do |port_name|
                            "<#{port_name}> #{port_name}"
                        end.join("|")
                        label << "|"
                    end
                    label << "<main> #{task_label}"
                    if !outputs[child_name].empty?
                        label << "|"
                        label << outputs[child_name].map do |port_name|
                            "<#{port_name}> #{port_name}"
                        end.join("|")
                    end
                    label << "}"

                    io << "  C#{id}#{child_name} [label=\"#{label}\"];"
                    #io << "  C#{id} -> C#{id}#{child_name}"
                end
                io << "}"

                model.specializations.each do |specialized_model|
                    specialized_id = specialized_model.composition.object_id
                    # io << "C#{id} -> C#{specialized_id} [ltail=cluster_#{id} lhead=cluster_#{specialized_id} weight=2];"

                    composition_to_dot(io, specialized_model.composition)
                end
            end

            def to_dot
                io = []
                io << "digraph {\n"
                io << "  node [shape=record,height=.1];\n"
                io << "  compound=true;\n"
                io << "  rankdir=TB;"

                models = each_composition.to_a
                models.each do |m|
                    composition_to_dot(io, m)
                end
                io << "}"
                io.join("\n")
            end
        end
    end
end

