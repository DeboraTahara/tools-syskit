module Syskit
    module Coordination
        module TaskScriptExtension
	    # Waits until this data writer is {InputWriter#ready?}
	    def wait_until_ready(writer)
		poll do
		    if writer.ready?
			transition!
		    end
		end
	    end

            def method_missing(m, *args, &block)
                if m.to_s =~ /_port$/
                    instance_for(model.root).send(m, *args, &block)
                else super
                end
            end
        end
    end
end
Roby::Coordination::TaskScript.include Syskit::Coordination::TaskScriptExtension
