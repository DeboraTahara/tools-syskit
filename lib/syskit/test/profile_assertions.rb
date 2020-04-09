module Syskit
    module Test
        # Defines assertions for definitions (Syskit::Actions::Profile) or
        # actions that are created from these definitions
        # (Roby::Actions::Interface)
        #
        # It assumes that the test class was extended using
        # {ProfileModelAssertions}
        module ProfileAssertions
            include NetworkManipulation

            class ProfileAssertionFailed < Roby::ExceptionBase
                attr_reader :actions

                def initialize(act, original_error)
                    @actions = Array(act)
                    super([original_error])
                end

                def pretty_print(pp)
                    pp.text "Failure while running an assertion on"
                    pp.nest(2) do
                        actions.each do |act|
                            pp.breakable
                            act.pretty_print(pp)
                        end
                    end
                end
            end

            # Validates an argument that can be an action, an action collection
            # (e.g. a profile) or an array of action, and normalizes it into an
            # array of actions
            #
            # @raise [ArgumentError] if the argument is invalid
            def Actions(arg)
                if arg.respond_to?(:each_action)
                    arg.each_action.map(&:to_action)
                elsif arg.respond_to?(:to_action)
                    [arg.to_action]
                elsif arg.respond_to?(:flat_map)
                    arg.flat_map { |a| Actions(a) }
                else
                    raise ArgumentError, "expected an action or a collection of actions, but got #{arg}"
                end
            end

            # Like #Actions, but expands coordination models into their
            # consistuent actions
            def AtomicActions(arg, &block)
                Actions(arg).flat_map do |action|
                    expand_coordination_models(action)
                end
            end

            # Like {#AtomicActions} but filters out actions that cannot be
            # handled by the bulk assertions, and returns them
            #
            # @param [Array,Action] arg the action that is expanded
            # @param [Array<Roby::Actions::Action>] actions that
            #   should be ignored. Actions are compared on the basis of their
            #   model (arguments do not count)
            def BulkAssertAtomicActions(arg, exclude: [], &block)
                exclude = Actions(exclude).map(&:model)
                skipped_actions = Array.new
                actions = AtomicActions(arg).find_all do |action|
                    if exclude.include?(action.model)
                        false
                    elsif !action.kind_of?(Actions::Action) && action.has_missing_required_arg?
                        skipped_actions << action
                        false
                    else
                        true
                    end
                end
                skipped_actions.delete_if do |skipped_action|
                    actions.any? { |action| action.model == skipped_action.model }
                end
                return actions, skipped_actions
            end

            # Tests that a definition or all definitions of a profile are
            # self-contained, that is that the only variation points in the
            # profile are profile tags.
            #
            # If given a profile as argument, or no profile at all, will test on
            # all definitions of resp. the given profile or the test's subject
            #
            # Note that it is a really good idea to maintain this property. No.
            # Seriously. Keep it in your tests.
            def assert_is_self_contained(action_or_profile = subject_syskit_model, message: "%s is not self contained", exclude: [], **instanciate_options)
                actions, skipped_actions = BulkAssertAtomicActions(action_or_profile, exclude: exclude)
                if !skipped_actions.empty?
                    flunk "could not validate #{skipped_actions.size} non-Syskit actions: #{skipped_actions.map(&:name).sort.join(", ")}, pass them to the 'exclude' argumet to #{__method__}"
                end

                actions.each do |act|
                    begin
                        self.assertions += 1
                        syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                        task = syskit_deploy(act, syskit_engine: syskit_engine,
                                             compute_policies: false, compute_deployments: false,
                                             validate_generated_network: false, **instanciate_options)
                        # Get rid of all the tasks that
                        still_abstract = plan.find_local_tasks(Syskit::Component)
                            .abstract.to_set
                        still_abstract &= plan.compute_useful_tasks([task])
                        tags, other = still_abstract.partition { |task| task.class <= Actions::Profile::Tag }
                        tags_from_other = tags.find_all { |task| task.class.profile != subject_syskit_model }
                        if !other.empty?
                            raise Roby::Test::Assertion.new(TaskAllocationFailed.new(syskit_engine, other)), message % [act.to_s]
                        elsif !tags_from_other.empty?
                            other_profiles = tags_from_other.map { |t| t.class.profile }.uniq
                            raise Roby::Test::Assertion.new(TaskAllocationFailed.new(syskit_engine, tags)), "#{act} contains tags from another profile (found #{other_profiles.map(&:name).sort.join(", ")}, expected #{subject_syskit_model}"
                        end

                        plan.unmark_mission_task(task)
                        expect_execution.garbage_collect(true).to_run
                    rescue Exception => e
                        raise ProfileAssertionFailed.new(act, e), e.message
                    end
                end
            end

            # Spec-style call for {#assert_is_self_contained}
            #
            # @example verify that all definitions of a profile are self-contained
            #   describe MyBundle::Profiles::MyProfile do
            #     it { is_self_contained }
            #   end
            def is_self_contained(action_or_profile = subject_syskit_model, options = Hash.new)
                assert_is_self_contained(action_or_profile, options)
            end

            # Tests that the following definition can be successfully
            # instanciated in a valid, non-abstract network.
            #
            # If given a profile, it will perform the test on each action of the
            # profile taken in isolation. If you want to test whether actions
            # can be instanciated at the same time, use
            # {#assert_can_instanciate_together}
            #
            # If called without argument, it tests the spec's context profile
            def assert_can_instanciate(action_or_profile = subject_syskit_model, exclude: [])
                actions, skipped_actions = BulkAssertAtomicActions(action_or_profile, exclude: exclude)
                if !skipped_actions.empty?
                    flunk "could not validate #{skipped_actions.size} non-Syskit actions: #{skipped_actions.map(&:name).sort.join(", ")}, pass them to the 'exclude' argumet to #{__method__}"
                end

                actions.each do |action|
                    task = assert_can_instanciate_together(action)
                    plan.unmark_mission_task(task)
                    expect_execution.garbage_collect(true).to_run
                end
            end

            # Spec-style call for {#assert_can_instanciate}
            #
            # @example verify that all definitions of a profile can be instanciated
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate }
            #   end
            def can_instanciate(action_or_profile = subject_syskit_model)
                assert_can_instanciate(action_or_profile)
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together, i.e. that the resulting network is valid and
            # non-abstract (does not contain abstract tasks or data services)
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def assert_can_instanciate_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                syskit_deploy(AtomicActions(actions),
                              compute_policies: false,
                              compute_deployments: false)
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_instanciate_together}
            #
            # @example verify that all definitions of a profile can be instanciated all at the same time
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate_together }
            #   end
            def can_instanciate_together(*actions)
                assert_can_instanciate_together(*actions)
            end

            # @api private
            #
            # Given an action, returns the list of atomic actions it refers to
            def expand_coordination_models(action)
                if action.model.respond_to?(:coordination_model)
                    actions = action.model.coordination_model.each_task.flat_map do |coordination_task|
                        if coordination_task.respond_to?(:action)
                            expand_coordination_models(coordination_task.action)
                        end
                    end.compact
                else
                    [action]
                end
            end

            # Tests that the following syskit-generated actions can be deployed,
            # that is they result in a valid, non-abstract network whose all
            # components have a deployment
            #
            # If given a profile, it will perform the test on each action of the
            # profile taken in isolation. If you want to test whether actions
            # can be deployed at the same time, use
            # {#assert_can_deploy_together}
            #
            # If called without argument, it tests the spec's context profile
            def assert_can_deploy(action_or_profile = subject_syskit_model, exclude: [])
                actions, skipped_actions = BulkAssertAtomicActions(action_or_profile, exclude: exclude)
                if !skipped_actions.empty?
                    flunk "could not validate #{skipped_actions.size} non-Syskit actions: #{skipped_actions.map(&:name).sort.join(", ")}, pass them to the 'exclude' argument to #{__method__}"
                end

                actions.each do |action|
                    task = assert_can_deploy_together(action)
                    plan.unmark_mission_task(task)
                    expect_execution.garbage_collect(true).to_run
                end
            end

            # Spec-style call for {#assert_can_deploy}
            #
            # @example verify that each definition of a profile can be deployed
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_deploy }
            #   end
            def can_deploy(action_or_profile = subject_syskit_model)
                assert_can_deploy(action_or_profile)
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {assert_can_instanciate_together}
            def assert_can_deploy_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                syskit_deploy(AtomicActions(actions),
                              compute_policies: true,
                              compute_deployments: true)
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_deploy_together}
            #
            # @example verify that all definitions of a profile can be deployed at the same time
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_deploy_together }
            #   end
            def can_deploy_together(*actions)
                assert_can_deploy_together(*actions)
            end

            # Tests that the given syskit-generated actions can be deployed together
            # and that the task contexts #configure method can be called
            # successfully
            #
            # It requires running the actual deployments, even though the components
            # themselve never get started
            #
            # It is stronger (and therefore includes)
            # {assert_can_deploy_together}
            def assert_can_configure_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                roots = assert_can_deploy_together(*AtomicActions(actions))
                # assert_can_deploy_together has one of its idiotic return
                # interface that returns either a single task if a single action
                # was given, or an array otherwise. I'd like to have someone
                # to talk me out of this kind of ideas.
                tasks = plan.compute_useful_tasks(Array(roots))
                task_contexts = tasks.find_all { |t| t.kind_of?(Syskit::TaskContext) }
                    .each do |task_context|
                        if !task_context.plan
                            raise ProfileAssertionFailed.new(actions, nil), "#{task_context} got garbage-collected before it got configured"
                        end
                    end
                syskit_configure(task_contexts)
                roots
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_configure_together}
            def can_configure_together(*actions)
                assert_can_configure_together(*actions)
            end
        end
    end
end
