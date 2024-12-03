# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module ProcessManagers
        describe Unmanaged do
            attr_reader :process_manager, :task_model, :unmanaged_task, :deployment_task

            before do
                @unmanaged_task_name =
                    "syskit-unmanaged_deployment_test-#{Process.pid}-#{rand}"
            end

            describe "using the default name service" do
                before do
                    @task_model = Syskit::TaskContext.new_submodel
                    @process_manager = register_unmanaged_manager("unmanaged_tasks")
                    use_unmanaged_task task_model => @unmanaged_task_name
                    @task = syskit_deploy(task_model)
                    @deployment_task = @task.execution_agent
                    plan.unmark_mission_task(@task)
                end

                after do
                    if deployment_task.running?
                        expect_execution { deployment_task.stop! }
                            .to { emit deployment_task.stop_event }
                    end

                    unmanaged_task&.dispose
                end

                it "sets the deployment's process name's to the specified name" do
                    assert_equal @unmanaged_task_name, deployment_task.process_name
                end

                it "readies the execution agent when the task becomes available" do
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to do
                            emit deployment_task.start_event
                            not_emit deployment_task.ready_event
                        end

                    create_unmanaged_task
                    expect_execution.to { emit deployment_task.ready_event }
                    task = deployment_task.task(@unmanaged_task_name)
                    assert_equal unmanaged_task, task.orocos_task
                end

                it "stopping the process causes the monitor thread to quit" do
                    make_deployment_ready
                    execute { plan.remove_task(@task) }
                    monitor_thread = deployment_task.orocos_process.monitor_thread
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.success_event }
                    refute deployment_task.orocos_process.monitor_thread.alive?
                    assert deployment_task.orocos_process.dead?
                    refute monitor_thread.alive?
                end

                it "allows to kill a started deployment that was not ready" do
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to { emit deployment_task.start_event }
                    expect_execution { deployment_task.stop! }
                        .join_all_waiting_work(false)
                        .to { emit deployment_task.stop_event }
                end

                it "allows to kill a deployment that is ready" do
                    make_deployment_ready
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.stop_event }
                end

                it "aborts the execution agent if the monitor thread fails "\
                "in unexpected ways" do
                    make_deployment_ready

                    process_died = capture_log(deployment_task, :warn) do
                        background_thread_died =
                            capture_log(deployment_task.orocos_process, :fatal) do
                                expect_execution do
                                    deployment_task
                                        .orocos_process.monitor_thread
                                        .raise RuntimeError
                                end.to { emit deployment_task.failed_event }
                            end
                        assert_equal ["assuming #{deployment_task.orocos_process} died "\
                                      "because the background thread died with",
                                      "RuntimeError (RuntimeError)"],
                                     background_thread_died
                    end
                    assert_equal ["#{@unmanaged_task_name} unexpectedly died "\
                                  "on process server unmanaged_tasks"],
                                 process_died
                end

                it "deregisters the process object of the process whose thread failed" do
                    make_deployment_ready
                    process = deployment_task.orocos_process
                    process_manager = process.process_manager
                    begin
                        flexmock(process).should_receive(dead?: true)
                        flexmock(process)
                            .should_receive(:verify_threads_state)
                            .and_raise(RuntimeError)
                        capture_log(process, :fatal) do
                            assert_equal [process],
                                         process_manager.wait_termination(0).keys
                            assert_equal({}, process_manager.wait_termination(0))
                        end
                    ensure (
                        process_manager.processes[@unmanaged_task_name] = process
                    )
                    end
                end

                it "stops the deployment if the remote task becomes unavailable" do
                    make_deployment_ready
                    messages = capture_log(deployment_task, :warn) do
                        expect_execution do
                            delete_unmanaged_task
                            # Synchronize on the monitor thread explicitely, otherwise
                            # the RTT state read might kick in first and bypass the
                            # whole purpose of the test
                            assert_raises(Orocos::ComError) do
                                deployment_task.orocos_process.monitor_thread.join
                            end
                            assert deployment_task.orocos_process.dead?
                        end.to { emit deployment_task.failed_event }
                    end
                    assert_equal ["#{@unmanaged_task_name} unexpectedly died on "\
                                  "process server unmanaged_tasks"],
                                 messages
                end

                # This is really a heisentest .... previous versions of
                # UnmanagedProcess would fail when this happened but the current
                # implementation should be completely imprevious
                it "handles concurrently having the monitor fail and #kill being called" \
                do
                    make_deployment_ready
                    expect_execution do
                        delete_unmanaged_task
                        deployment_task.orocos_process.kill
                    end.to { emit deployment_task.stop_event }
                end
            end

            describe "specifying the name service" do
                attr_reader :name_service

                before do
                    @task_model = Syskit::TaskContext.new_submodel
                    @name_service = Orocos::Local::NameService.new
                    @process_manager =
                        register_unmanaged_manager("new_unmanaged_tasks").manager
                    use_unmanaged_task(task_model => @unmanaged_task_name,
                                       on: "new_unmanaged_tasks")
                    @task = syskit_deploy(task_model)
                    @deployment_task = @task.execution_agent
                    plan.unmark_mission_task(@task)
                end

                it "allows to specify the name service used to resolve tasks" do
                    create_unmanaged_task
                    name_service.register @unmanaged_task

                    process = process_manager.start(
                        @unmanaged_task_name, deployment_task.model.orogen_model
                    )
                    result = process.wait_running
                    assert_includes(result, @unmanaged_task_name)
                    assert_kind_of(String, result[@unmanaged_task_name])
                    assert_match(/^IOR:/, result[@unmanaged_task_name])
                end
            end

            def create_unmanaged_task
                raise ArgumentError, "unmanaged task already created" if @unmanaged_task

                @unmanaged_task = Orocos.allow_blocking_calls do
                    Orocos::RubyTasks::TaskContext.from_orogen_model(
                        @unmanaged_task_name, task_model.orogen_model
                    )
                end
            end

            def make_deployment_ready
                expect_execution do
                    create_unmanaged_task
                    deployment_task.start!
                end.to { emit deployment_task.ready_event }
            end

            def delete_unmanaged_task
                unmanaged_task.dispose
                @unmanaged_task = nil
            end
        end
    end
end
