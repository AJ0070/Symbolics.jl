using SymbolicUtils: FnType, Sym

const IndexMap = Dict{Char,Char}(
            '0' => '₀',
            '1' => '₁',
            '2' => '₂',
            '3' => '₃',
            '4' => '₄',
            '5' => '₅',
            '6' => '₆',
            '7' => '₇',
            '8' => '₈',
            '9' => '₉')

"""
$(TYPEDEF)

A named variable which represents a numerical value. The variable is uniquely
identified by its `name`, and all variables with the same `name` are treated
as equal.

# Fields
$(FIELDS)

For example, the following code defines an independent variable `t`, a parameter
`α`, a function parameter `σ`, a variable `x`, which depends on `t`, a variable
`y` with no dependents, a variable `z`, which depends on `t`, `α`, and `x(t)`
and parameters `β₁` and `β₂`.


```julia
t = Num(Variable{ModelingToolkit.Parameter{Real}}(:t))  # independent variables are treated as known
α = Num(Variable{ModelingToolkit.Parameter{Real}}(:α))  # parameters are known
σ = Num(Variable{ModelingToolkit.FnType{Tuple{Any},Real}}(:σ)) # left uncalled, since it is used as a function
w = Num(Variable{ModelingToolkit.FnType{Tuple{Any},Real}}(:w)) # unknown, left uncalled
x = Num(Variable{ModelingToolkit.FnType{Tuple{Any},Real}}(:x))(t)  # unknown, depends on `t`
y = Num(Variable(:y))   # unknown, no dependents
z = Num(Variable{ModelingToolkit.FnType{NTuple{3,Any},Real}}(:z))(t, α, x)  # unknown, multiple arguments
β₁ = Num(Variable(:β, 1)) # with index 1
β₂ = Num(Variable(:β, 2)) # with index 2

expr = β₁ * x + y^α + σ(3) * (z - t) - β₂ * w(t - 1)
```
"""
struct Variable{T} <: Function # backward compat
    """The variable's unique name."""
    name::Symbol
    Variable(name) = Sym{Real}(name)
    Variable{T}(name) where T = Sym{T}(name)
    function Variable{T}(name, indices...) where T
        var_name = Symbol("$(name)$(join(map_subscripts.(indices), "ˏ"))")
        Sym{T}(var_name)
    end
end

function Variable(name, indices...)
    var_name = Symbol("$(name)$(join(map_subscripts.(indices), "ˏ"))")
    Variable(var_name)
end

# TODO: move this to Symutils
function Sym{T}(name, i, indices...) where T
    var_name = Symbol("$(name)$(join(map_subscripts.((i, indices...,)), "ˏ"))")
    Sym{T}(var_name)
end

function map_subscripts(indices)
    str = string(indices)
    join(IndexMap[c] for c in str)
end

rename(x::Sym{T},name) where T = Sym{T}(name)
function rename(x::Symbolic, name)
    if operation(x) isa Sym
        rename(operation(x), name)(arguments(x)...)
    else
        error("can't rename $x to $name")
    end
end

# Build variables more easily
function _parse_vars(macroname, type, x)
    ex = Expr(:block)
    var_names = Symbol[]
    # if parsing things in the form of
    # begin
    #     x
    #     y
    #     z
    # end
    x = x isa Tuple && first(x) isa Expr && first(x).head == :tuple ? first(x).args : x # tuple handling
    x = flatten_expr!(x)
    for _var in x
        iscall = isa(_var, Expr) && _var.head == :call
        isarray = isa(_var, Expr) && _var.head == :ref
        issym  = _var isa Symbol
        @assert iscall || isarray || issym "@$macroname expects a tuple of expressions or an expression of a tuple (`@$macroname x y z(t) v[1:3] w[1:2,1:4]` or `@$macroname x, y, z(t) v[1:3] w[1:2,1:4]`)"

        if iscall
            var_name, expr = _construct_vars(_var.args[1], type, _var.args[2:end])
        else
            var_name, expr = _construct_vars(_var, type, nothing)
        end
        push!(var_names, var_name)
        push!(ex.args, expr)
    end
    rhs = build_expr(:tuple, var_names)
    push!(ex.args, :(($(var_names...),) = $rhs))
    return ex
end

function _construct_vars(_var, type, call_args)
    issym  = _var isa Symbol
    isarray = isa(_var, Expr) && _var.head == :ref
    if isarray
        var_name = _var.args[1]
        indices = _var.args[2:end]
        expr = _construct_array_vars(var_name, type, call_args, indices...)
    else
        # Implicit 0-args call
        var_name = _var
        expr = _construct_var(var_name, type, call_args)
    end
    var_name, :($var_name = $expr)
end

function _construct_var(var_name, type, call_args)
    expr = if call_args === nothing
        :($Num($Sym{$type}($(Meta.quot(var_name)))))
    elseif !isempty(call_args) && call_args[end] == :..
        :($Num($Sym{$FnType{Tuple, $type}}($(Meta.quot(var_name))))) # XXX: using Num as output
    else
        :($Num($Sym{$FnType{NTuple{$(length(call_args)), Any}, $type}}($(Meta.quot(var_name)))($(map(x->:($value($x)), call_args)...))))
    end
end

function _construct_var(var_name, type, call_args, ind)
    # TODO: just use Sym here
    if call_args === nothing
        :($Num($Sym{$type}($(Meta.quot(var_name)), $ind...)))
    elseif !isempty(call_args) && call_args[end] == :..
        :($Num($Sym{$FnType{Tuple{Any}, $type}}($(Meta.quot(var_name)), $ind...))) # XXX: using Num as output
    else
        :($Num($Sym{$FnType{NTuple{$(length(call_args)), Any}, $type}}($(Meta.quot(var_name)), $ind...)($(map(x->:($value($x)), call_args)...))))
    end
end

function _construct_array_vars(var_name, type, call_args, indices...)
    :(map(Iterators.product($(indices...))) do ind
        $(_construct_var(var_name, type, call_args, :ind))
    end)
end


"""

Define one or more unknown variables.

```julia
@parameters t α σ(..) β[1:2]
@variables w(..) x(t) y z(t, α, x)

expr = β₁* x + y^α + σ(3) * (z - t) - β₂ * w(t - 1)
```

`(..)` signifies that the value should be left uncalled.

Sometimes it is convenient to define arrays of variables to model things like `x₁,…,x₃`.
The `@variables` macro supports this with the following syntax:

```julia
@variables x[1:3];
x

3-element Vector{Num}:
 x₁
 x₂
 x₃

# support for arbitrary ranges and tensors
@variables y[2:3,1:5:6];
y

2×2 Matrix{Num}:
 y₂ˏ₁  y₂ˏ₆
 y₃ˏ₁  y₃ˏ₆

# also works for dependent variables
@variables t z[1:3](t);
z

3-element Array{Num,1}:
 z₁(t)
 z₂(t)
 z₃(t)
```
"""
macro variables(xs...)
    esc(_parse_vars(:variables, Real, xs))
end

TreeViews.hastreeview(x::Sym) = true

function TreeViews.treelabel(io::IO,x::Sym,
                             mime::MIME"text/plain" = MIME"text/plain"())
  show(io,mime,Text(x.name))
end
