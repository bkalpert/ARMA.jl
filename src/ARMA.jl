module ARMA

using Polynomials, NLsolve

export
    estimate_covariance,
    fitARMA,
    fit_exponentials,
    ARMAModel,
    generate_noise,
    model_covariance,
    model_psd,
    toeplitz_whiten

# ARMA.jl includes the basic ARMA models and their use
# model_selection.jl includes tools for choosing a model (p,q) order
#   and for fitting the best model of that order.

include("model_selection.jl")


"An Autoregressive Moving-Average model of order (p,q).

There are three alternative ways to construct the model:

1. `ARMAModel(thetacoef::Vector, phicoef::Vector)`
2. `ARMAModel(roots_::Vector, poles::Vector, variance::Float64)`
3. `ARMAModel(bases::Vector, amplitudes::Vector, covarianceIV::Vector)`

The first method specifies the model by the coefficients of its rational function representation.
The ordering of the coefficients is constant first, high-order last: `c[1]+c[2]*z+c[3]*z^2...`
Here, `thetacoef` represents the numerator of the forward transform and `phicoef` the denominator.
By convention, the value `phicoef[1]` is 1.0, but both polynomials will be rescaled to achieve
this before calling the inner constructor. To ensure a stable, invertible ARMA model,

The second method specifies the model by the roots and poles of its rational function
representation, along with a variance (that is, covariance at lag=0). The latter is necessary
to specify the overall scale of the model, because roots and poles are insensitive to scale.
All roots and poles must have absolute value greater than 1, to ensure a stable, invertible
ARMA model.

The third specifies the model by its covariance function, represented as a sum of (potentially
complex) exponentials, with 0 or more initial values of the covariance (`covarianceIV`) that
violate the general pattern.  For `ARMAModel(b, a, cIV)`, the covariance at lag t is either
`cIV[t]` when `t<=length(cIV)`, or else `sum(b .* (a.^t))`. For any base and amplitude pair
(bi,ai) where either has a non-zero imaginary part, it is required that (conj(bi),conj(ai))
also be among the base and amplitude pairs. This requirement ensures that the covariance is
everywhere real. Also, we require |b|<1 for all bases to ensure a stable model.

Methods 1 and 2 can create ARMA(p,q) models of arbitrary order. A pure AR(p) model with q=0 can be
generated by passing `thetacoef=[X]` or `roots_=[]` to the methods 1 and 2 constructors,
respectively. Similarly, a pure MA(q) model with p=0 can be generated using
`phicoef=[1]` or `poles=[]`. Method 3 generates an ARMA(p,q) model where p is the length of both
the `bases` and `amplitudes` vectors, and where q = p-1+length(covarianceIV).  While models of
lower MA order are possible in principle, they are not well-matched to the sum-of-exponentials
representation, because setting q<p-1 imposes complicated restrictions on the relative amplitudes
of the exponentials."

type ARMAModel
    p         ::Int
    q         ::Int
    roots_    ::Vector{Complex128}
    poles     ::Vector{Complex128}
    thetacoef ::Vector{Float64}
    phicoef   ::Vector{Float64}
    covarIV   ::Vector{Float64}
    expbases  ::Vector{Complex128}
    expampls  ::Vector{Complex128}

    function ARMAModel(p,q,roots_,poles,thetacoef,phicoef,covarIV,expbases,expampls)
        @assert p == length(poles)
        @assert q == length(roots_)
        @assert all(abs2(poles) .> 1)
        @assert all(abs2(roots_) .> 1)
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

"Go from theta,phi polynomials to the sum-of-exponentials representation.
Returns (covar_initial_values, exponential_bases, exponential_amplitudes)."

function _covar_repr(thetacoef::Vector, phicoef::Vector)
    roots_ = roots(Poly(thetacoef))
    poles = roots(Poly(phicoef))
    expbases = 1.0 ./ poles
    q = length(roots_)
    p = length(poles)
    n = max(p,q)

    # Find the initial, exceptional values
    phi = zeros(Float64, n+1)
    phi[1:p+1] = phicoef
    P = zeros(Float64, n+1, n+1)
    for r=1:n+1
        for c=1:r
            P[r,c] = phi[r-c+1]
        end
    end
    theta = zeros(Float64, n+1)
    theta[1:q+1] = thetacoef
    psi = P \ theta

    T = zeros(Float64, n+1, n+1)
    for r=1:n+1
        for c=1:n+2-r
            T[r,c] = theta[c+r-1]
        end
    end
    P2 = zeros(Float64, n+1, n+1)
    for r=1:n+1
        for i=1:p+1
            c = r-i+1
            if c<1; c = 2-c; end
            P2[r,c] += phi[i]
        end
    end

    gamma = P2 \ (T*psi)
    XI = Array{Complex128}(p, p)
    lowestpower = p >= q ? 1 : 1+q-p
    for c=1:p
        XI[1,c] = expbases[c] ^ lowestpower
        for r=2:p
            XI[r,c] = expbases[c] * XI[r-1,c]
        end
    end
    expampls = XI \ model_covariance(gamma, phicoef, p+lowestpower)[end+1-p:end]
    gamma, expbases, expampls
end


# Construct from theta and phi polynomial representation
function ARMAModel(thetacoef::Vector, phicoef::Vector)
    theta = thetacoef * phicoef[1] * sign(thetacoef[1])
    phi = phicoef / phicoef[1]
    roots_ = roots(Poly(theta))
    poles = roots(Poly(phi))
    @assert all(abs2(roots_) .> 1)
    @assert all(abs2(poles) .> 1)
    q = length(roots_)
    p = length(poles)

    covarIV, expbases, expampls = _covar_repr(theta, phi)
    ARMAModel(p,q,roots_,poles,theta,phi,covarIV,expbases,expampls)
end


"Form the coefficients of a polynomial from the given roots `r`.
It is assumed that the coefficients are real, so only the real part is kept.
The sign of the constant term is taken to be positive.
The highest-order term has coefficient +1 or -1."

function polynomial_from_roots(r::Vector)
    pr = prod(r)
    @assert abs(imag(pr)/real(pr)) < 1e-10
    coef = real(poly(r).a)
    coef * sign(coef[1])
end


# Construct from roots-and-poles representation. We also need the gamma_0 value
# (the process variance) to set the scale of the model, as roots-and-poles omits this.
function ARMAModel(roots_::Vector, poles::Vector, variance)
    @assert all(abs2(roots_) .> 1)
    @assert all(abs2(poles) .> 1)
    # The product of the roots and the product of the poles needs to be real.
    pr = prod(roots_)
    pp = prod(poles)
    @assert abs(imag(pr)/real(pr)) < 1e-10
    @assert abs(imag(pp)/real(pp)) < 1e-10
    q = length(roots_)
    p = length(poles)

    # Construct normalized MA and AR polynomials.
    # Note that we will NOT have the proper scale at first.
    thetac = polynomial_from_roots(roots_)
    phic = polynomial_from_roots(poles)
    thetacoef = thetac / thetac[1]
    phicoef = phic / phic[1]

    covarIV, expbases, expampls = _covar_repr(thetacoef, phicoef)

    # Now that we know the normalized model's covariance, rescale
    # theta, covariance, and the exponential amplitudes to correct it.
    scale = sqrt(variance / covarIV[1])
    covarIV *= variance / covarIV[1]
    ARMAModel(p,q,roots_,poles,thetacoef*scale,phicoef,covarIV,expbases,expampls*scale)
end


# Construct ARMAModel from a sum-of-exponentials representation, along with
# zero or more exceptional values of the initial covariance, covarIV.
# It is allowed for covarIV==[], but it can't be optional,
# else this constructor will get mixed up with the thetacoef,phicoef one.
# The model will have order ARMA(p,q) where p=length(bases)=length(amplitudes),
# and q=p-1+length(covarIV).

function ARMAModel(bases::Vector, amplitudes::Vector, covarIV::Vector)
    p = length(bases)
    @assert p == length(amplitudes)
    q = p-1+length(covarIV)

    # Find the covariance from lags 0 to p+q. Call it gamma
    gamma = zeros(Float64, 1+p+q)
    t = 0:p+q
    for i=1:p
        gamma += real(amplitudes[i] * (bases[i] .^ t))
    end
    gamma[1:length(covarIV)] = covarIV

    # Find the phi polynomial
    poles = 1.0 ./ bases
    phic = polynomial_from_roots(poles)
    phicoef = phic / phic[1]

    # Find the nonlinear system of equations for the theta coefficients
    LHS = zeros(Float64, 1+q)
    for t=0:q
        for i=1:p+1
            for j=1:p+1
                LHS[t+1] += phicoef[i]*phicoef[j]*gamma[1+abs(t+i-j)]
            end
        end
    end

    # Solve the system
    function f!(x, residual)
        q = length(residual)-1
        for t = 0:q
            residual[t+1] = LHS[t+1]
            for j = 0:q-t
                residual[t+1] -= x[j+1]*x[j+t+1]
            end
        end
        residual
    end
    thetacoef = ones(Float64, q+1)
    results = nlsolve(f!, thetacoef)
    roots_ = roots(Poly(results.zero))

    # Now a clever trick: any roots r of the MA polynomial that are INSIDE
    # the unit circle can be replaced by 1/r and yield the same covariance.
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
    thetacoef *= sqrt(gamma[1]/gammanorm[1]) *  sign(thetacoef[1])

    ARMAModel(p,q,roots_,poles,thetacoef,phicoef,gamma[1:max(p,q+1)],bases,amplitudes)
end


"generate a simulated noise timeseries from an ARMAModel of length N"
function generate_noise(m::ARMAModel, N::Int)
    # eps = white N(0,1) noise; x = after MA process; z = after inverting AR
    eps = randn(N+m.q)
    eps[1:m.p] = 0
    x = zeros(Float64, N)
    z = zeros(Float64, N)
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


"The ARMA model's model covariance function, from lags 0 to N-1"
function model_covariance(covarIV::Vector, phicoef::Vector, N::Int)
    covar = zeros(Float64, N)
    covar[1:length(covarIV)] = covarIV[1:end]
    @assert phicoef[1] == 1.0
    for i = length(covarIV)+1:N
        for j = 1:length(phicoef)-1
            covar[i] -= phicoef[j+1] * covar[i-j]
        end
    end
    covar
end
model_covariance(m::ARMAModel, N::Int) = model_covariance(m.covarIV, m.phicoef, N)


"The ARMA model's power spectral density function"
function model_psd(m::ARMAModel, N::Int)
    freq = collect(linspace(0,0.5,N))
    model_psd(m, freq)
end

function model_psd(m::ARMAModel, freq::Vector)
    z = exp(-2im*pi *freq)
    numer = m.thetacoef[1]
    for i=1:m.q
        numer += m.thetacoef[i+1] * (z.^i)
    end
    denom = m.phicoef[1]
    for i=1:m.p
        denom += m.phicoef[i+1] * (z.^i)
    end
    abs2(numer ./ denom)
end

"Approximately whiten the timestream using a Toeplitz matrix (so
that a zero-padded delay of the input timestream is equivalent to a
zero-padded delay of the output).

No Toeplitz matrix has the ability to make the input exactly white,
but for many purposes, the time-shift property is more valuable than
that exact whitening."
function toeplitz_whiten(m::ARMAModel, timestream::Vector)
    N = length(timestream)
    white = zeros(Float64, N)

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

function toeplitz_whiten!(m::ARMAModel, timestream::Vector)
    timestream[1:end] = toeplitz_whiten(m, timestream)
end

end # module
