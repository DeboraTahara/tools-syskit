# frozen_string_literal: true

def init
    super
    sections.place(:ports, :dataflow, :hierarchy).before(:constructor_details)
end

def ports
    return unless object[:syskit]
    return unless (@ports = object.syskit.ports)

    erb(:ports)
end

def dataflow
    return unless object[:syskit]
    return unless (@svg = object.syskit.dataflow_graph_path)

    erb(:dataflow)
end

def hierarchy
    return unless object[:syskit]
    return unless (@svg = object.syskit.hierarchy_graph_path)

    erb(:hierarchy)
end
