module Syskit
    # Representation of a component port on a component instance.
    #
    # The sibling class Syskit::Models::Port represents a port on a component
    # model. For instance, an object of class Syskit::Models::Port could
    # be used to represent a port on a subclass of TaskContext while
    # Syskit::Port would represent it for an object of that subclass.
    class Port
        # The port model
        # @return [Models::Port]
        attr_reader :model
        # The component model this port is part of
        attr_reader :component
        # The port name
        def name; model.name end
        # The port type
        def type; model.type end

        def ==(other_port)
            other_port.class == self.class &&
                other_port.model == self.model &&
                other_port.component == self.component
        end

        def initialize(model, component)
            @model, @component = model, component
        end

        def hash; component.hash | name.hash end
        def eql?(other)
            self == other
        end

        def inspect; to_s end
        def pretty_print(pp)
            pp.text "port #{name} of "
            component.pretty_print(pp)
        end

        # Returns the port attached to a proper Component instance that
        # corresponds to self
        #
        # @raise [ArgumentError] if it is not possible (for instance, ports on
        #   InstanceRequirements are not associated with a component port)
        # @return [Port] the resolved port
        def to_component_port
            if !component.respond_to?(:self_port_to_component_port)
                raise ArgumentError, "cannot call #to_component_port on ports of #{component}"
            end
            component.self_port_to_component_port(self)
        end

        # Returns the port attached to a TaskContext instance that corresponds
        # to self
        #
        # @raise [ArgumentError] if it is not possible (for instance, ports on
        #   InstanceRequirements are not associated with a component port)
        # @return [Port] the resolved port
        def to_actual_port
            component_port = to_component_port
            component_port.component.self_port_to_actual_port(component_port)
        end

        # Returns the orocos port attached that corresponds to self
        #
        # @raise [ArgumentError] if it is not possible (for instance, ports on
        #   InstanceRequirements are not associated with a component port)
        # @return [Orocos::Port] the resolved port
        def to_orocos_port
            component_port = to_actual_port
            component_port.component.self_port_to_orocos_port(component_port)
        end

        # Connects this port to the other given port, using the given policy
        def connect_to(in_port, policy = Hash.new)
            out_port = self.to_component_port
            if out_port == self
                if in_port.respond_to?(:to_component_port)
                    in_port = in_port.to_component_port
                    if !output?
                        raise WrongPortConnectionDirection.new(self, in_port), "cannot connect #{self} to #{in_port}: #{self} is not an output port"
                    elsif !in_port.input?
                        raise WrongPortConnectionDirection.new(self, in_port), "cannot connect #{self} to #{in_port}: #{in_port} is not an input port"
                    elsif component == in_port.component
                        raise SelfConnection.new(self, in_port), "cannot connect #{self} to #{in_port}: they are both ports of the same component"
                    elsif self.type != in_port.type
                        raise WrongPortConnectionTypes.new(self, in_port), "cannot connect #{self} to #{in_port}: types mismatch"
                    end
                    component.connect_ports(in_port.component, [name, in_port.name] => policy)
                else
                    Syskit.connect self, in_port, policy
                end

            else
                out_port.connect_to(in_port, policy)
            end
        end

        def disconnect_from(in_port)
            out_port = self.to_component_port
            if out_port == self
                in_port = in_port.to_component_port
                component.disconnect_ports(in_port.component, [[out_port.name, in_port.name]])
            else
                out_port.disconnect_from(in_port)
            end
        end

        def connected_to?(in_port)
            out_port = self.to_component_port
            if out_port == self
                in_port = in_port.to_component_port
                component.child_object?(in_port.component, Flows::DataFlow) &&
                    component[in_port.component, Flows::DataFlow].has_key?([out_port.name, in_port.name])
            else
                out_port.connected_to?(in_port)
            end
        end

        def new_sample
            model.new_sample
        end

        # @return [Boolean] true if this is an output port, false otherwise.
        #   The default implementation returns false
        def output?; false end
        # @return [Boolean] true if this is an input port, false otherwise.
        #   The default implementation returns false
        def input?; false end

        def to_s
            "#{component}.#{name}"
        end

        def connected?
            each_connection { return true }
            false
        end

        def static?; model.orogen_model.static? end
    end

    class InputPort < Port
        # Enumerates all ports connected to this one
        def each_connection
            port = to_component_port
            port.component.each_input_connection(port.name) do |out_task, out_port_name, in_port_name, policy|
                yield(out_task.find_output_port(out_port_name), policy)
            end
            self
        end

        def writer(policy = Hash.new)
            InputWriter.new(self, policy)
        end

        # Enumerates all ports connected to this one
        def each_concrete_connection
            port = to_component_port
            port.component.each_concrete_input_connection(port.name) do |out_task, out_port_name, in_port_name, policy|
                yield(out_task.find_output_port(out_port_name), policy)
            end
            self
        end

        def input?; true end
    end

    class OutputPort < Port
        def to_data_source
            OutputReader.new(self)
        end

        def reader(policy = Hash.new)
            OutputReader.new(self, policy)
        end

        # Enumerates all ports connected to this one
        def each_connection
            port = to_component_port
            port.component.each_output_connection(port.name) do |_, in_port_name, in_task, policy|
                yield(in_task.find_input_port(in_port_name), policy)
            end
            self
        end

        # Enumerates all ports connected to this one
        def each_concrete_connection
            port = to_component_port
            port.component.each_concrete_output_connection(port.name) do |_, in_port_name, in_task, policy|
                yield(in_task.find_input_port(in_port_name), policy)
            end
            self
        end

        def output?; true end
    end

    # Base class for output reader/input writer
    class PortAccessor
        # The port for which this is a writer
        # @return [Syskit::OutputPort]
        attr_reader :port
        # The port actually resolved. This is different from #port if #port is
        # on an abstract task that got replaced
        # @return [Syskit::OutputPort]
        attr_reader :resolved_port
        # The actual port, when resolved. This is the port on the TaskContext
        # object that actually serves the data
        # @return [Syskit::OutputPort]
        attr_reader :actual_port
        # The connection policy
        attr_reader :policy

        def initialize(port, policy = Hash.new)
            @port = port.to_component_port
            @policy = policy
            @disconnected = false
            schedule_resolution(@port) do |resolved_port, _|
                @resolved_port = resolved_port
            end
        end

        private def schedule_resolution(port)
            port.component.execute do |component|
                unless @disconnected
                    resolved_port = component.find_port(port.name)
                    unless resolved_port
                        raise ArgumentError,
                            "cannot find a port called #{port.name} on #{component}"
                    end

                    @actual_port = resolved_port.to_actual_port
                    yield(resolved_port, @actual_port) if block_given?

                    if @actual_port.static? || @actual_port.component.setup?
                        resolve(component, @actual_port)
                    else
                        @actual_port.component.execute do
                            resolve(component, @actual_port)
                        end
                    end
                end
            end
        end

        # @api private
        #
        # Resolves the underlying writer object
        private def resolve(main, port, accessor)
            distance = port.component.distance_to_syskit

            resolver = main.promise(description: "#{port}##{accessor} for #{self}") do
                port.to_orocos_port.public_send(accessor, distance: distance, **policy)
            end
            resolver.on_success(description: "#{self}#resolve#ready") do |obj|
                unless @disconnected
                    yield(obj)
                end
            end
            resolver.on_error(description: "#{self}#resolve#failed") do |error|
                actual_component = port.component
                actual_component.execution_engine.
                    add_error(PortAccessFailure.new(error, actual_component))
            end
            resolver.execute
        end
    end

    # A data source for a port attached to a component
    class OutputReader < PortAccessor
        # The actual data reader itself
        # @return [Orocos::OutputReader]
        attr_reader :reader

        def model
            Models::OutputReader.new(port.model, policy)
        end

        # @api private
        #
        # Resolves the underlying reader object
        def resolve(main, port)
            super(main, port, :reader) { |r| @reader = r }
        end

        def disconnect
            @disconnected = true
            if actual_reader = self.reader
                actual_port.component.execution_engine.promise(description: "disconnect #{self}") do
                    begin actual_reader.disconnect
                    rescue Orocos::ComError
                    end
                end.on_success { @reader = nil }.execute
            end
        end

        def read_new(sample = nil)
            reader.read_new(sample) if reader
        end

        def read
            reader.read if reader
        end

        def ready?
            reader && actual_port.component.running?
        end

        def connected?
            reader && reader.connected?
        end
    end

    # A data writer for a port attached to a component
    class InputWriter < PortAccessor
        # The actual data writer itself
        # @return [Orocos::InputWriter]
        attr_reader :writer

        def model
            Models::InputWriter.new(port.model, policy)
        end

        def ready?
            writer && actual_port.component.running?
        end

        def connected?
            writer && writer.connected?
        end

        def disconnect
            @disconnected = true
            if actual_writer = self.writer
                actual_port.component.execution_engine.promise(description: "disconnect #{self}") do
                    begin actual_writer.disconnect
                    rescue Orocos::ComError
                    end
                end.on_success { @writer = nil }.execute
            end
        end

        # @api private
        #
        # Resolves the underlying writer object
        def resolve(main, port)
            super(main, port, :writer) { |w| @writer = w }
        end

        # Write a sample on the associated port
        #
        # @return [Boolean] true if the writer was in a state that allowed
        #   writing to the actual task, false otherwise
        def write(sample)
            if ready?
                writer.write(sample)
            else
                Typelib.from_ruby(sample, port.type)
                nil
            end
        end

        def new_sample
            @port.new_sample
        end
    end
end
