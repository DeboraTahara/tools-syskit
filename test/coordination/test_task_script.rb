require 'syskit/test'

describe Syskit::Coordination::TaskScriptExtension do
    include Syskit::SelfTest

    it "sets the CompositionChild instance as model for child tasks" do
        data_service = Syskit::DataService.new_submodel { output_port 'out', '/double' }
        composition_m = Syskit::Composition.new_submodel do
            add data_service, :as => 'test'
        end
        assert_equal composition_m.test_child, composition_m.script.test_child.model.model
    end

    describe "model-level scripts" do
        attr_reader :base_srv_m, :srv_m, :component_m, :composition_m
        before do
            @base_srv_m = Syskit::DataService.new_submodel do
                input_port 'base_in', '/int'
                output_port 'base_out', '/int'
            end
            @srv_m = Syskit::DataService.new_submodel do
                input_port 'srv_in', '/int'
                output_port 'srv_out', '/int'
            end
            srv_m.provides base_srv_m, 'base_in' => 'srv_in', 'base_out' => 'srv_out'
            @component_m = stub_syskit_task_context_model 'Task' do
                input_port 'in', '/int'
                output_port 'out', '/int'
            end
            component_m.provides srv_m, :as => 'test'
            @composition_m = Syskit::Composition.new_submodel
            composition_m.add base_srv_m, :as => 'test'
        end

        describe "mapping ports from services using submodel creation" do
            def start
                component = syskit_deploy_task_context(component_m)
                composition_m = self.composition_m.new_submodel
                composition_m.overload 'test', component_m
                composition = composition_m.use('test' => component).instanciate(plan)
                plan.add_permanent(composition)
                syskit_start_component(composition)
                syskit_start_component(component)
                return composition, component
            end

            it "gives writer access to input ports mapped from services" do
                writer = nil
                composition_m.script do
                    writer = test_child.base_in_port.writer
                    begin
                        test_child.base_in_port.to_component_port
                    rescue
                    end
                end
                composition, component = start
                writer.write(10)
                assert_equal 10, composition.test_child.orocos_task.in.read
            end

            it "gives reader access to input ports mapped from services" do
                reader = nil
                composition_m.script do
                    reader = test_child.base_out_port.reader
                end
                composition, component = start
                composition.test_child.orocos_task.out.write(10)
                assert_equal 10, reader.read
            end
        end

        describe "mapping ports from services using dependency injection" do
            def start
                component = syskit_deploy_task_context(component_m)
                composition = composition_m.use('test' => component).instanciate(plan)
                plan.add_permanent(composition)
                syskit_start_component(composition)
                syskit_start_component(component)
                return composition, component
            end

            it "gives writer access to input ports mapped from services" do
                writer = nil
                composition_m.script do
                    writer = test_child.base_in_port.writer
                end
                composition, component = start
                writer.write(10)
                assert_equal 10, composition.test_child.orocos_task.in.read
            end

            it "gives reader access to input ports mapped from services" do
                reader = nil
                composition_m.script do
                    reader = test_child.base_out_port.reader
                end
                composition, component = start
                composition.test_child.orocos_task.out.write(10)
                assert_equal 10, reader.read
            end
        end

        it "gives writer access to input ports" do
            writer = nil
            component_m.script do
                writer = in_port.writer
            end
            component = syskit_deploy_task_context(component_m)
            syskit_start_component(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.in.read
        end

        it "gives access to output ports" do
            reader = nil
            component_m.script do
                reader = out_port.reader
            end
            component = syskit_deploy_task_context(component_m)
            syskit_start_component(component)
            component.orocos_task.out.write(10)
            assert_equal 10, reader.read
        end
    end

    describe "input port access" do
        attr_reader :component, :srv_m

        before do
            @srv_m = srv_m = Syskit::DataService.new_submodel { input_port 'srv_in', '/double' }
            @component = syskit_deploy_task_context 'Task' do
                input_port 'in', '/double'
                provides srv_m, :as => 'test'
            end
        end

        it "returns input port instances" do
            port = component.script.in_port
            assert_kind_of Syskit::InputPort, port
        end

        it "gives access to input ports when created at the instance level" do
            writer = nil
            component.script do
                writer = in_port.writer
            end

            start_task_context(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.in.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            assert_kind_of Syskit::InputPort, composition_m.script.test_child.srv_in_port
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            composition = composition_m.use('test' => component).instanciate(plan)

            writer = nil
            composition.script do
                writer = test_child.srv_in_port.writer
            end

            syskit_start_component(composition)
            syskit_start_component(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.in.read
        end

        it "generates an error if trying to access a non-existent port" do
            begin
                component.script do
                    non_existent_port
                end
                flunk("out_port did not raise NoMethodError")
            rescue NoMethodError => e
                assert_equal :non_existent_port, e.name
            end
        end
    end

    describe "output port access" do
        attr_reader :component, :srv_m

        before do
            @srv_m = srv_m = Syskit::DataService.new_submodel { output_port 'srv_out', '/double' }
            @component = syskit_deploy_task_context 'Task' do
                output_port 'out', '/double'
                provides srv_m, :as => 'test'
            end
        end

        it "returns output port instances" do
            port = component.script.out_port
            assert_kind_of Syskit::OutputPort, port
        end

        it "gives access to output ports" do
            reader = nil
            component.script do
                reader = out_port.reader
            end

            start_task_context(component)
            component.orocos_task.out.write(10)
            assert_equal 10, reader.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            assert_kind_of Syskit::OutputPort, composition_m.script.test_child.srv_out_port
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            composition = composition_m.use('test' => component).instanciate(plan)

            reader = nil
            composition.script do
                reader = test_child.srv_out_port.reader
            end

            start_task_context(composition)
            start_task_context(component)
            component.orocos_task.out.write(10)
            assert_equal 10, reader.read
        end

        it "generates an error if trying to access a non-existent port" do
            begin
                component.script do
                    non_existent_port
                end
                flunk("out_port did not raise NoMethodError")
            rescue NoMethodError => e
                assert_equal :non_existent_port, e.name
            end
        end
    end


end

