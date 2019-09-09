module ARMA

using Polynomials, NLsolve, HDF5
using LinearAlgebra
using Statistics
using ToeplitzMatrices

export
    estimate_covariance,
    fitARMA,
    fit_exponentials,
    ARMAModel,
    generate_noise,
    model_covariance,
    model_psd,
    ARMASolver,
    whiten,
    unwhiten,
    mult_covariance,
    solve_covariance,
    inverse_covariance,
    toeplitz_whiten

# ARMA.jl includes the basic ARMA models and their use
# model_selection.jl includes tools for choosing a model (p,q) order
#   and for fitting the best model of that order.

include("model_selection.jl")


"""
    ARMAModel(...)

An Autoregressive Moving-Average model of order (p,q).

There are three alternative ways to construct the model:

1. `ARMAModel(thetacoef::Vector, phicoef::Vector)`
2. `ARMAModel(roots_::Vector, poles::Vector, variance::Float64)`
3. `ARMAModel(bases::Vector, amplitudes::Vector, covarianceIV::Vector)`

The first method specifies the model by the coefficients of its rational
function representation. The ordering of the coefficients is constant first,
high-order last: `c[1]+c[2]*z+c[3]*z^2...` Here, `thetacoef` represents the
numerator of the forward transform and `phicoef` the denominator. By convention,
the value `phicoef[1]` is 1.0, but both polynomials will be rescaled to achieve
this before calling the inner constructor. To ensure a stable, invertible ARMA
model, the roots of both polynomials should have absolute values greater than 1.

The second method specifies the model by the roots and poles of its rational
function representation, along with a variance (that is, covariance at lag=0).
The latter is necessary to specify the overall scale of the model, because roots
and poles are insensitive to scale. All roots and poles must have absolute value
greater than 1, to ensure a stable, invertible ARMA model.

The third specifies the model by its covariance function, represented as a sum
of (potentially complex) exponentials, with 0 or more initial values of the
covariance (`covarianceIV`) that violate the general pattern.  For `ARMAModel(b,
a, cIV)`, the covariance at lag `j-1` is either `cIV[j]` when `j<=length(cIV)`,
or else `sum(b .* (a.^t))`. For any base and amplitude pair (bi,ai) where either
has a non-zero imaginary part, it is required that (conj(bi),conj(ai)) also be
among the base and amplitude pairs. This requirement ensures that the covariance
is everywhere real. Also, we require `|b|<1` for all bases to ensure a stable
model.

Methods 1 and 2 can create ARMA(p,q) models of arbitrary order. A pure AR(p)
model with q=0 can be generated by passing `thetacoef` of length 1 or
`roots_=[]` to the methods 1 and 2 constructors, respectively. Similarly, a pure
MA(q) model with p=0 can be generated using `phicoef` of length 1 or `poles=[]`.
Method 3 generates an ARMA(p,q) model where p is the length of both the `bases`
and `amplitudes` vectors, and where q = p-1+length(covarianceIV).  While models
of MA order `q<p-1` are possible in principle, they are not well-matched to the
sum-of-exponentials representation, because setting `q<p-1` imposes complicated
restrictions on the relative amplitudes of the exponentials.

When an `ARMAModel` is constructed by any of these methods, all three
representations are computed and stored.

See also: [`ARMASolver`](@ref) for fast mutliplies and solves of either the
noise model covariance matrix or its Cholesky factor.
"""
mutable struct ARMAModel
    p         ::Int
    q         ::Int
    roots_    ::Vector{ComplexF64}
    poles     ::Vector{ComplexF64}
    thetacoef ::Vector{Float64}
    phicoef   ::Vector{Float64}
    covarIV   ::Vector{Float64}
    expbases  ::Vector{ComplexF64}
    expampls  ::Vector{ComplexF64}

    function ARMAModel(p,q,roots_,poles,thetacoef,phicoef,covarIV,expbases,expampls)
        @assert p == length(poles)
        @assert q == length(roots_)
        @assert all(abs2.(poles) .> 1)
        @assert all(abs2.(roots_) .> 1)
        @assert p+1 == length(phicoef)
        @assert q+1 == length(thetacoef)
        @assert p == length(expbases)
        @assert p == length(expampls)
        @assert length(covarIV) >= 1+q
        @assert length(covarIV) >= p
        @assert thetacoef[1] > 0
        @assert phicoef[1] == 1.0
        # Note that these consistency checks don't cover everything. Specifically, we
        # do not test the consistency of the 3 representations with each other. That's
        # done only in the 3 outer constructors.
        new(p,q,roots_,poles,thetacoef,phicoef,covarIV,expbases,expampls)
    end
end


function Base.show(io::IO, m::ARMAModel)
    print(io, "ARMAModel(p=$(m.p), q=$(m.q))\n")
    print(io, "[Amplitude, Exponential base]\n")
    for i=1:m.p
        print(io, "(A,B)[$i]: $(m.expampls[i]),  $(m.expbases[i])\n")
    end
    print(io, "Initial covar: $(m.covarIV)\n")
end

"Go from theta,phi polynomials to the sum-of-exponentials representation.
Returns (covar_initial_values, exponential_bases, exponential_amplitudes)."
function _covar_repr(thetacoef::Vector, phicoef::Vector)
    roots_ = roots(Poly(thetacoef))
    poles = roots(Poly(phicoef))
    expbases = 1.0 ./ poles
    q = length(roots_)
    p = length(poles)
    n = max(p,q)

    # Find the initial, exceptional values.

    # psi comes from Brockwell 3.3.3 or delta in Pollock 17.87.
    phi = fill(0.0, n+1)
    phi[1:p+1] = phicoef
    P = TriangularToeplitz(phi, :L) # lower-triangular toeplitz
    theta = fill(0.0, n+1)
    theta[1:q+1] = thetacoef
    psi = P \ theta

    T = fill(0.0, n+1, n+1) # A Hankel matrix containing theta in first col.
    for r=1:n+1
        for c=1:n+2-r
            T[r,c] = theta[c+r-1]
        end
    end
    P2 = fill(0.0, n+1, n+1)
    for r=1:n+1
        for i=1:p+1
            c = r-i+1
            if c<1; c = 2-c; end
            P2[r,c] += phi[i]
        end
    end
    gamma = P2 \ (T*psi)

    # Work in the range where exceptional values no longer hold.
    # XI[r,c] = expbases[c]^(r-1-lowestpower)
    # lowestpower is chosen to make the top row be beyond the 1+q-p expectional values.
    XI = Array{ComplexF64}(undef, p, p)
    lowestpower = p >= q ? 1 : 1+q-p
    for c=1:p
        XI[:,c] = expbases[c] .^ collect(lowestpower:p+lowestpower-1)
    end
    expampls = XI \ model_covariance(gamma, phicoef, p+lowestpower)[1+lowestpower:p+lowestpower]
    gamma, expbases, expampls
end


# Construct from theta and phi polynomial representation
function ARMAModel(thetacoef::Vector, phicoef::Vector)
    # Normalize the input coefficient vectors
    theta = thetacoef / phicoef[1]
    if theta[1] < 0
        theta = -theta
    end
    phi = phicoef / phicoef[1]
    roots_ = roots(Poly(theta))
    poles = roots(Poly(phi))
    @assert all(abs2.(roots_) .> 1)
    @assert all(abs2.(poles) .> 1)
    q = length(roots_)
    p = length(poles)

    covarIV, expbases, expampls = _covar_repr(theta, phi)
    ARMAModel(p,q,roots_,poles,theta,phi,covarIV,expbases,expampls)
end

WhiteModel() = ARMAModel([1.0], [1.0])

"Form the coefficients of a polynomial from the given roots `r`.
It is assumed that the coefficients are real, so only the real part is kept.
The zero-order term (the first) has coefficient +1. Fails if 0 is a root."
function polynomial_from_roots(r::AbstractVector)
    pr = prod(r)
    @assert abs(imag(pr)/real(pr)) < 1e-10
    coef = real(poly(r).a)
    coef / coef[1]
end


# Construct from roots-and-poles representation. We also need the gamma_0 value
# (the process variance) to set the scale of the model, as roots-and-poles omits this.
function ARMAModel(roots_::AbstractVector, poles::AbstractVector, variance::Real)
    @assert all(abs2.(roots_) .> 1)
    @assert all(abs2.(poles) .> 1)
    # The product of the roots and the product of the poles needs to be real.
    pr = prod(roots_)
    pp = prod(poles)
    @assert abs(imag(pr)/real(pr)) < 1e-10
    @assert abs(imag(pp)/real(pp)) < 1e-10
    q = length(roots_)
    p = length(poles)

    # Construct normalized MA and AR polynomials.
    # Note that we will NOT have the proper scale at first.
    thetacoef = polynomial_from_roots(roots_)
    phicoef = polynomial_from_roots(poles)

    covarIV, expbases, expampls = _covar_repr(thetacoef, phicoef)

    # Now that we know the normalized model's covariance, rescale
    # theta, covariance, and the exponential amplitudes to correct it.
    scale = sqrt(variance / covarIV[1])
    covarIV .*= variance / covarIV[1]
    ARMAModel(p,q,roots_,poles,thetacoef*scale,phicoef,covarIV,expbases,expampls*scale)
end


function solveGammaMA(gammaMA::AbstractVector; maxiter=1000)
    # Solve the system gammaMA[i] = sum mu[j]*mu[j+i] for mu.
    # Goal: find a root ; if we cannot, at least find the lowest-cost
    # value of x (here, meaning the lowest mean absolute residual).

    # Strategy is step 1: iterative estimation of mu.
    # Step 2: full nonlinear solve for mu, if successful.

    function f!(residual, x)
        q = length(residual)-1
        for t = 0:q
            residual[t+1] = gammaMA[t+1]
            for j = 0:q-t
                residual[t+1] -= x[j+1]*x[j+t+1]
            end
        end
        residual
    end

    function cost(x)
        residual = fill(zero(eltype(x)), size(x))
        f!(residual, x)
        mean(abs.(residual))
    end

    n = length(gammaMA)
    theta = fill(0.0, n)
    theta[1] = 1
    var = gammaMA[1]
    besttheta = copy(theta)
    bestcost = Inf
    consecincreases = 0

    # Iterate until result gets worse 10 times in a row, the mean absolute deviation
    # from gamma is less than gammaMA[1]/10^6, or we reach the iteration limit.
    for iter = 1:maxiter
        theta[n] = gammaMA[n]/var
        for i=n-1:-1:2
            theta[i] = gammaMA[i]/var - dot(theta[2:n+1-i], theta[1+i:n])
        end
        var = gammaMA[1]/sum(theta.^2)
        c = cost(theta * sqrt(var))
        if c < 1e-6*gammaMA[1]
            besttheta[:] = theta[:]*sqrt(var)
            # println("Basic iteration succeeds")
            break
        end
        if c <= bestcost
            bestcost = c
            besttheta[:] = theta[:]*sqrt(var)
        else
            consecincreases += 1
            if consecincreases >= 10
                # println("10 consecutive increases as of iter = $(iter)")
                break
            end
        end
    end

    # Step 2: try a full nonlinear solver. Ignore result if it's worse or errors.
    try
        resid = 0*theta
        f!(resid, besttheta)
        results = nlsolve(f!, besttheta, iterations=maxiter)
        costnl = cost(results.zero)
        if costnl < bestcost
            # println("Solver succeeded: costnl=$(costnl) vs $(bestcost) ")
            return results.zero
        else
            # println("Solver costnl=$(costnl) vs $(bestcost)")
        end
    catch e
    end
    return besttheta
end

# Construct ARMAModel from a sum-of-exponentials representation, along with
# zero or more exceptional values of the initial covariance, covarIV.
# It is allowed for covarIV==[], but it can't be optional,
# else this constructor will get mixed up with the thetacoef,phicoef one.
# The model will have order ARMA(p,q) where p=length(bases)=length(amplitudes),
# and q=p-1+length(covarIV).

function ARMAModel(bases::AbstractVector, amplitudes::AbstractVector, covarIV::AbstractVector)
    p = length(bases)
    @assert p == length(amplitudes)
    q = p-1+length(covarIV)

    # Find the covariance from lags 0 to p+q. Call it gamma
    gamma = fill(0.0, 1+p+q+50)
    t = 0:length(gamma)-1
    for i=1:p
        gamma += real(amplitudes[i] * (bases[i] .^ t))
    end
    gamma[1:length(covarIV)] = covarIV

    # Find the phi polynomial
    poles = 1.0 ./ bases
    phicoef = polynomial_from_roots(poles)

    # Find the nonlinear system of equations for the theta coefficients
    gammaMA = fill(0.0, 1+q)
    for t=0:q
        for i=1:p+1
            for j=1:p+1
                gammaMA[t+1] += phicoef[i]*phicoef[j]*gamma[1+abs(t+i-j)]
            end
        end
    end

    besttheta = solveGammaMA(gammaMA)
    roots_ = roots(Poly(besttheta))

    # Now a clever trick: any roots r of the MA polynomial that are INSIDE
    # the unit circle can be replaced by 1/r and yield the same covariance.
    @assert q == length(roots_)
    for i=1:q
        if abs2(roots_[i]) < 1
            roots_[i] = 1.0/roots_[i]
        end
    end

    # Replace thetacoef, in case any roots moved
    thetacoef = polynomial_from_roots(roots_)

    # One last problem is that theta polynomial is normalized, with theta[end]=1,
    # which we don't want. Our approach is just to see what the normalized theta
    # would give for gamma[1] and rescale.
    gammanorm,_,_ = _covar_repr(thetacoef,phicoef)
    thetacoef .*= sqrt(gamma[1]/gammanorm[1])

    ARMAModel(p,q,roots_,poles,thetacoef,phicoef,gamma[1:max(p,q+1)],bases,amplitudes)
end


"""
    hdf5save(output, model::ARMAModel)

Store the `model` to an HDF5 file.

`output` may be an HDF5 file open for writing, an HDF5 group within such a file,
or the file name of an HDF5 file which will be created.
"""
function hdf5save(output::HDF5.DataFile, model::ARMAModel)
    GROUPNAME = "ARMAModel"
    if exists(output, GROUPNAME)
        o_delete(output, GROUPNAME)
    end
    grp = g_create(output, GROUPNAME)
    grp["basesR"] = real(model.expbases)
    grp["basesI"] = imag(model.expbases)
    grp["amplitudesR"] = real(model.expampls)
    grp["amplitudesI"] = imag(model.expampls)
    grp["covarIV"] = model.covarIV[1:max(model.p, model.q+1)-model.p]
    model
end

function hdf5save(filename::AbstractString, model::ARMAModel)
    h5open(filename, "w") do f
        hdf5save(f, model)
    end
end


"""
    model = hdf5load(input)

Load and return an `ARMAModel` object from `input`. The argument `input` can be
the "ARMAModel" group, the group that contains it, or the name of an HDF5 file
(group "ARMAModel" would need to be at the root of the file).
"""
function hdf5load(input::HDF5.DataFile)
    if exists(input, "ARMAModel")
        return hdf5load(input["ARMAModel"])
    end
    bases = input["basesR"][:] + 1im*input["basesI"][:]
    ampls = input["amplitudesR"][:] + 1im*input["amplitudesI"][:]
    covarIV = input["covarIV"][:]

    ARMAModel(bases, ampls, covarIV)
end

function hdf5load(filename::AbstractString)
    h5open(filename, "r") do f
        return hdf5load(f)
    end
end


"""
    generate_noise(m, N)

Generate a simulated noise timeseries of length `N` from an ARMAModel `m`.
"""
function generate_noise(m::ARMAModel, N::Int)
    # eps = white N(0,1) noise; x = after MA process; z = after inverting AR
    eps = randn(N+m.q)
    eps[1:m.p] = 0
    x = fill(0.0, N)
    z = fill(0.0, N)
    for i=1:m.q+1
        x += eps[i:end+i-m.p-1] * m.thetacoef[i]
    end
    for j=1:m.p
        z[j] = x[j]
        for i = 2:j
            z[j] -= m.phicoef[i] * z[j-i+1]
        end
    end
    for j=1+m.p:N
        z[j] = x[j]
        for i = 2:m.p+1
            z[j] -= m.phicoef[i] * z[j-i+1]
        end
    end
    z
end



"""
    model_covariance(...)

Compute the ARMA model's model covariance function. Methods:

1. `model_covariance(m::ARMAModel, N::Int)`
2. `model_covariance(covarIV::Vector, phicoef::Vector, N::Int)`

The first returns covariance of model `m` from lags 0 to `N-1`. The second
returns the covariance given the initial exceptional values of covariance
`covarIV` and the coefficients `phicoef` of the Phi polynomial. (From these
coefficients, a recusion allows computation of covariance beyond the initial
values.)
"""
function model_covariance(covarIV::AbstractVector, phicoef::AbstractVector, N::Int)
    if N < length(covarIV)
        return covarIV[1:N]
    end
    @assert(length(covarIV) >= length(phicoef)-1)
    if phicoef[1] != 1.0
        phicoef = phicoef/phicoef[1]
    end
    covar = fill(0.0, N)
    covar[1:length(covarIV)] = covarIV[1:end]

    # Use Pollock eq 17.86
    for i = length(covarIV)+1:N
        for j = 1:length(phicoef)-1
            covar[i] -= phicoef[j+1] * covar[i-j]
        end
    end
    covar
end
model_covariance(m::ARMAModel, N::Int) = model_covariance(m.covarIV, m.phicoef, N)


"""
    model_psd(m,...)

The ARMA model's power spectral density function. Methods:

1. `model_psd(m::ARMAModel, freq::Vector)`
1. `model_psd(m::ARMAModel, N::Int)`

The first returns PSD at the given frequencies `freq` (frequency 0.5 is the
critical, or Nyquist, frequency). The second returns PSD at `N` equally-spaced
frequencies from 0 to 0.5.
"""
function model_psd(m::ARMAModel, freq::AbstractVector)
    z = exp.(-2im*pi *freq)
    N = length(freq)
    numer = fill(complex(m.thetacoef[1]), N)
    for i=1:m.q
        numer .+= m.thetacoef[i+1] * (z.^i)
    end
    denom = fill(complex(m.phicoef[1]), N)
    for i=1:m.p
        denom .+= m.phicoef[i+1] * (z.^i)
    end
    abs2.(numer ./ denom)
end

model_psd(m::ARMAModel, N::Int) = model_psd(m, collect(range(0, stop=0.5, length=N)))


"""
    toeplitz_whiten(m, timestream)

Approximately whiten the timestream using a Toeplitz matrix. This has the
consequence that a zero-padded delay of the input timestream is equivalent to a
zero-padded delay of the output.

Returns the whitened timestream.

If `timestream` is a matrix, then each column is whitened, and the result is
returned.

No Toeplitz matrix has the ability to make the input exactly white,
but for many purposes, the time-shift property is more valuable than
that exact whitening.
"""
function toeplitz_whiten(m::ARMAModel, timestream::AbstractVector)
    N = length(timestream)
    white = fill(0.0, N)

    # First, multiply the input by the AR matrix (a banded Toeplitz
    # matrix with the phi coefficients on the diagonal and first p
    # subdiagonals).
    # The result is the MA matrix times the whitened data.
    MAonly = m.phicoef[1] * timestream
    for i=1:m.p
        MAonly[1+i:end] .+= m.phicoef[i+1] * timestream[1:end-i]
    end

    # Second, solve the MA matrix (also a banded Toeplitz matrix with
    # q non-zero subdiagonals.)
    white[1] = MAonly[1] / m.thetacoef[1]
    if N==1
        return white
    end
    for i = 2:min(m.q, N)
        white[i] = MAonly[i]
        for j = 1:i-1
            white[i] -= white[j]*m.thetacoef[1+i-j]
        end
        white[i] /= m.thetacoef[1]
    end
    for i = m.q+1:N
        white[i] = MAonly[i]
        for j = i-m.q:i-1
            white[i] -= white[j]*m.thetacoef[1+i-j]
        end
        white[i] /= m.thetacoef[1]
    end
    white
end

function toeplitz_whiten(m::ARMAModel, M::AbstractMatrix)
    tw(v::AbstractVector) = toeplitz_whiten(m, v)
    mapslices(tw, M, 1)
end


include("exact_operations.jl")

end # module
