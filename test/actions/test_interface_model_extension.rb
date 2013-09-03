require 'syskit/test'

describe Syskit::Actions::InterfaceModelExtension do
    include Syskit::SelfTest

    describe "#use_profile" do
        attr_reader :actions, :profile
        before do
            @actions = Class.new(Roby::Actions::Interface)
            @profile = Syskit::Actions::Profile.new(nil)
        end

        it "should export the profile definitions as actions" do
            task_m = Syskit::TaskContext.new_submodel
            req = task_m.to_instance_requirements
            actions = Roby::Actions::Interface.new_submodel
            profile = Syskit::Actions::Profile.new(nil)
            profile.define('def', task_m)
            actions.use_profile(profile)

            act = actions.find_action_by_name('def_def')
            assert act
            assert_equal req, act.requirements
            assert_equal task_m, act.returned_type
        end

        it "should be so that the exported definitions can be used using the normal action interface" do
            req = profile.define('def', Syskit::Component)
            actions.use_profile(profile)

            flexmock(req).should_receive(:as_plan).and_return(task = Roby::Task.new)
            act = actions.def_def.instanciate(plan)
            assert [task], plan.known_tasks.to_a
        end

        it "should make task arguments that do not have a default a required argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert arg.required
        end

        it "should not make arguments of Composition arguments of the action" do
            task_m = Syskit::Composition.new_submodel
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            assert action.arguments.empty?
        end

        it "should not make arguments of TaskContext arguments of the action" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            assert action.arguments.empty?
        end

        it "should make task arguments that do have a default an optional argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, :default => nil }
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert !arg.required
        end

        it "should not require arguments to be given to the newly defined action method if there are no required arguments" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, :default => nil }
            profile.define('test', task_m)
            actions.use_profile(profile)
            act = actions.new(plan)
            plan.add(act.test_def)
        end

        it "should accept to be given argument to the newly defined action method even if there are no required arguments" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, :default => nil }
            profile.define('test', task_m)
            actions.use_profile(profile)
            act = actions.new(plan)
            plan.add(task = act.test_def(:arg0 => 10))
            assert_equal Hash[:arg0 => 10], task.planning_task.requirements.arguments
        end

        it "should make task arguments that do not have a default but are selected in the instance requirements an optional argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m.with_arguments('arg0' => nil))
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert !arg.required
        end

        it "should pass the action arguments to the instanciated task context when Action#instanciate is called" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)
            act = actions.def_def.instanciate(plan, 'arg0' => 10)
            assert_equal 10, act.arg0
        end

        it "should pass the action arguments to the instanciated task context when the generated action method is called" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)

            actions = self.actions.new(plan)
            plan.add(act = actions.def_def(:arg0 => 10))
            assert_equal 10, act.arg0
        end
    end
end

