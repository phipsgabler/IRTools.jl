import Base: map, map!
import Core.Compiler: PhiNode, PiNode, ssamap, userefs
import MacroTools: walk

walk(x::PhiNode, inner, outer) =
  outer(PhiNode(x.edges,
                [inner(isassigned(x.values, i) ? x.values[i] : undef)
                 for i in 1:length(x.values)]))

walk(x::PiNode, inner, outer) = outer(PiNode(inner(x.val), x.typ))

map(f, br::Branch) = Branch(br, condition = f(br.condition), args = f.(br.args))

function map(f, b::BasicBlock)
  stmts = map(x -> Statement(x, expr = f(x.expr)), b.stmts)
  branches = map(br -> map(f, br), b.branches)
  BasicBlock(stmts, b.args, b.argtypes, branches)
end

function map!(f, b::BasicBlock)
  map!(x -> Statement(x, expr = f(x.expr)), b.stmts, b.stmts)
  map!(br -> Branch(br, condition = f(br.condition), args = f.(br.args)), b.branches, b.branches)
  return b
end

function map!(f, b::Block)
  map!(f, BasicBlock(b))
end

function map(f, ir::IR)
  IR(ir.defs, map.(f, ir.blocks), ir.lines, ir.meta)
end

function map!(f, ir::IR)
  for b in blocks(ir)
    map!(f, b)
  end
  return ir
end

walk(st::Statement, inner, outer) = Statement(st, expr = inner(st.expr))
walk(bb::BasicBlock, inner, outer) = map(inner, bb)
walk(bb::Branch, inner, outer) = map(inner, bb)
walk(b::Block, inner, outer) = walk(BasicBlock(b), inner, outer)

walk(ir::IR, inner, outer) = outer(map(inner, ir))

prewalk!(f, ir::Union{IR,Block}) = map!(x -> prewalk(f, x), ir)
postwalk!(f, ir::Union{IR,Block}) = map!(x -> postwalk(f, x), ir)

varmap(f, x) = prewalk(x -> x isa Variable ? f(x) : x, x)

exprtype(x::GlobalRef; typeof = Typeof) = isconst(x.mod, x.name) ? typeof(getfield(x.mod, x.name)) : Any

exprtype(ir::IR, x::GlobalRef; typeof = Typeof) = exprtype(x, typeof = typeof)
exprtype(ir::IR, x::QuoteNode; typeof = Typeof) = typeof(x.value)
exprtype(ir::IR, x::Expr; typeof = Typeof) = error(x)
exprtype(ir::IR, x; typeof = Typeof) = typeof(x)

function exprtype(ir::IR, x::Variable; typeof = Typeof)
  b, i = get(ir.defs, x.id, (-1, -1))
  b == -1 && error("No such variable $x")
  if i > 0
    widenconst(ir[x].type)
  else
    widenconst(ir.blocks[b].argtypes[-i])
  end
end

function exprline(ir::IR, x::Variable)
  b, i = get(ir.defs, x.id, (-1, -1))
  i > 0 || return
  get(ir.lines, ir[x].line, nothing)
end


@eval begin
    # since var"#module#" does not work in pre-1.3
    struct XCall
        $(Symbol("#module#"))::Module
    end
end

function getproperty(x::XCall, name::Symbol)
    mod = getfield(x, Symbol("#module#"))
    if name === Symbol("#module#")
        return mod
    else
        return (args...; kwargs...) -> xcall(mod, name, args...; kwargs...)
    end
end


"""
`BaseCall.<bla>(args...; kwargs...)` is a hack to produce the properly namespaced expression for
BaseCall.<bla>(args...; kwargs...).
"""
const BaseCall = XCall(Base)


function xcall(_f, args...; kwargs...)
    if isempty(kwargs)
        Expr(:call, _f, args...)
    else
        keys = QuoteNode[]
        values = Any[]
        for (k, v) in kwargs
            push!(keys, QuoteNode(k))
            push!(values, v)
        end

        _call(args...) = Expr(:call, args...)
        _apply_type = GlobalRef(Core, :apply_type)
        _NamedTuple = GlobalRef(Core, :NamedTuple)
        _tuple = GlobalRef(Core, :tuple)
        _kwfunc = GlobalRef(Core, :kwfunc)
        
        _namedtuple = _call(_apply_type, _NamedTuple, _call(_tuple, keys...))
        _kws = _call(_namedtuple, _call(_tuple, values...))
        return _call(_call(_kwfunc, _f), _kws, _f, args...)
    end
end

xcall(mod::Module, f::Symbol, args...; kwargs...) =
    xcall(GlobalRef(mod, f), args...; kwargs...)
xcall(f::Symbol, args...; kwargs...) = xcall(GlobalRef(Base, f), args...; kwargs...)
