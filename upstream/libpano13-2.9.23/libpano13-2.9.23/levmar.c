/////////////////////////////////////////////////////////////////////////////////
//
//  Sparse levenberg marquardt algorithm. The algorithm is similar to
//  minpack's lmdif algorithm except that optimizations for sparse matrices
//  are used.
//
//  Copyright (C) 2021 Florian Königstein
//  
//  The code was developed by taking minpack's lmdif algorithm and replacing
//  where necessary the dense matrix operations by sparse matrix operations.
//  The algorithm depends on the SuiteSparse project 
//  (by Christopher Lourenco, JinHao Chen, Erick Moreno-Centeno,
//  and Timothy A.Davis) and optionally on the NVIDIA GPU Computing Toolkit
//  (copyright NVIDIA, 2701 San TomasExpressway, Santa Clara, CA 95050).
//  Some code and ideas are borrowed from the the sparseLM library
//  (by Manolis Lourakis).
//  Copyright notice of minpack: march 1980 argonne national laboratory.
//  Burton S. Garbow, Kenneth E. Hillstrom, Jorge J. More
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
/////////////////////////////////////////////////////////////////////////////////

//#define WITH_NVIDIA_CUDA_GPU_SUPPORT

#include "levmar.h"

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <memory.h>
#include <inttypes.h>

#include <cholmod.h>
#include <SuiteSparseQR_C.h>

#ifdef WITH_NVIDIA_CUDA_GPU_SUPPORT
#include <cuda_runtime.h>
#include "cuda.h"
#endif

static const double MACHEP = 1.2e-16;

/* smallest nonzero number */
static const double DWARF = 1.0e-38; // in enorm 3.834e-20
static const double RGIANT = 1.304e19;

#ifdef WITH_DEBUG_PRINT_MATRIX_VECTOR
void print_matrix_C(char* str, double* M, int64_t n, int64_t m)
{
    int64_t i, j;
    printf("%s :\n", str);
    for (i = 0; i < n; i++)
    {
        for (j = 0; j < m; j++)
            printf("%.16f  ", M[i + n * j]);
        printf("\n");
    }
    printf("\n");
}

void print_vector_C(char* str, double* v, int64_t m)
{
    int64_t j;
    printf("%s :\n", str);
    for (j = 0; j < m; j++)
        printf("%.16f  ", v[j]);
    printf("\n\n");
}

void print_int_vector_C(char* str, int64_t* v, int64_t m)
{
    int64_t j;
    printf("%s :\n", str);
    for (j = 0; j < m; j++)
        printf("%lld  ", v[j]);
    printf("\n\n");
}
#endif


#ifdef WITH_NVIDIA_CUDA_GPU_SUPPORT
int cudaInitDevice(CUcontext* cuContext)
{
    int selectedDevice = 0;
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if (deviceCount == 0)
    {
        return 0;
    }

    if (selectedDevice >= deviceCount)
    {
        return 0;
    }

    CUdevice cuDevice;

    return CUDA_SUCCESS == cuDeviceGet(&cuDevice, selectedDevice) &&
        CUDA_SUCCESS == cuCtxCreate(cuContext, CU_CTX_MAP_HOST | CU_CTX_BLOCKING_SYNC, cuDevice);
}

void cudaReleaseDevice(CUcontext* cuContext)
{
    CUresult cerr;
    cerr = cuCtxDestroy(*cuContext);
}
#endif

static double enorm(int64_t n, double x[])
{
    /*
    *     **********
    *
    *     function enorm
    *
    *     given an n-vector x, this function calculates the
    *     euclidean norm of x.
    *
    *     the euclidean norm is computed by accumulating the sum of
    *     squares in three different sums. the sums of squares for the
    *     small and large components are scaled so that no overflows
    *     occur. non-destructive underflows are permitted. underflows
    *     and overflows do not occur in the computation of the unscaled
    *     sum of squares for the intermediate components.
    *     the definitions of small, intermediate and large components
    *     depend on two constants, rdwarf and rgiant. the main
    *     restrictions on these constants are that rdwarf**2 not
    *     underflow and rgiant**2 not overflow. the constants
    *     given here are suitable for every known computer.
    *
    *     the function statement is
    *
    *	double precision function enorm(n,x)
    *
    *     where
    *
    *	n is a positive integer input variable.
    *
    *	x is an input array of length n.
    *
    *     subprograms called
    *
    *	fortran-supplied ... dabs,dsqrt
    *
    *     argonne national laboratory. minpack project. march 1980.
    *     burton s. garbow, kenneth e. hillstrom, jorge j. more
    *
    *     **********
    */
    int64_t i;
    double agiant, s1, s2, s3, xabs, x1max, x3max;
    double temp;

    s1 = 0.0;
    s2 = 0.0;
    s3 = 0.0;
    x1max = 0.0;
    x3max = 0.0;
    agiant = RGIANT / ((double)n);

    for (i = 0; i < n; i++)
    {
        xabs = fabs(x[i]);
        if ((xabs > DWARF) && (xabs <agiant))
        {
            /*
            *	    sum for intermediate components.
            */
            s2 += xabs * xabs;
            continue;
        }

        if (xabs > DWARF)
        {
            /*
            *	       sum for large components.
            */
            if (xabs > x1max)
            {
                temp = x1max / xabs;
                s1 = 1.0 + s1 * temp * temp;
                x1max = xabs;
            }
            else
            {
                temp = xabs / x1max;
                s1 += temp * temp;
            }
            continue;
        }
        /*
        *	       sum for small components.
        */
        if (xabs > x3max)
        {
            temp = x3max / xabs;
            s3 = 1.0 + s3 * temp * temp;
            x3max = xabs;
        }
        else
        {
            if (xabs != 0.0)
            {
                temp = xabs / x3max;
                s3 += temp * temp;
            }
        }
    }
    /*
    *     calculation of norm.
    */
    if (s1 != 0.0)
    {
        return x1max * sqrt(s1 + (s2 / x1max) / x1max);
    }
    if (s2 != 0.0)
    {
        if (s2 >= x3max)
            temp = s2 * (1.0 + (x3max / s2) * (x3max * s3));
        else
            temp = x3max * ((s2 / x3max) + (x3max * s3));
        return sqrt(temp);
    }
    else
    {
        return x3max * sqrt(s3);
    }
}

/* convert a matrix from the CRS format to CCS. If crs->val is NULL, only the nonzero pattern is converted */
/* ccs must already have been allocated and have the same nr, nc and nnz */
SuiteSparse_long splm_crsm2ccsm(splm_crsm* crs, splm_ccsm* ccs)
{
    register SuiteSparse_long i, j, k, l;
    SuiteSparse_long nr, nc, nnz, jmax;
    SuiteSparse_long* colidx, * rowptr, * rowidx, * colptr;
    SuiteSparse_long* colcounts; // counters for the number of nonzeros in each column

    nr = crs->nr; nc = crs->nc;
    nnz = crs->nnz;

    if (0 == (colcounts = (SuiteSparse_long*)malloc(nc * sizeof(SuiteSparse_long))))
    {
        return -1;
    }

    ccs->nr = nr; ccs->nc = nc; // ensure that ccs has the correct dimensions

    colidx = crs->colidx; rowptr = crs->rowptr;
    rowidx = ccs->rowidx; colptr = ccs->colptr;

    for (j = 0; j < nc; j++)
        colcounts[j] = 0;

    /* 1st pass: count #nonzeros in each column */

    for (j = rowptr[nr]; 0 != j; )
        ++(colcounts[colidx[--j]]);

    /* 2nd pass: copy every nonzero to its right position into the CCS structure */
    for (j = k = 0; j < nc; ++j)
    {
        colptr[j] = k;
        k += colcounts[j];
        colcounts[j] = 0; // clear to avoid separate loop below
    }
    colptr[nc] = nnz;

    /* colcounts[j] will count the #nonzeros in col. j seen before the current row */

    if (crs->val) { // are there any values to copy?
        register double* crsv, * ccsv;

        crsv = crs->val; ccsv = ccs->val;
        for (i = 0; i < nr; ++i)
        {
            jmax = rowptr[i + 1];
            for (j = rowptr[i]; j < jmax; ++j)
            {
                l = colidx[j];
                k = colptr[l];
                k += colcounts[l]++;

                rowidx[k] = i;

                /* copy values */
                ccsv[k] = crsv[j];
            }
        }
    }
    else
    { // no values, copy just structure
        for (i = 0; i < nr; ++i)
        {
            jmax = rowptr[i + 1];
            for (j = rowptr[i]; j < jmax; ++j)
            {
                l = colidx[j];
                k = colptr[l];
                k += colcounts[l]++;

                rowidx[k] = i;
            }
        }
    }

    free(colcounts);
    return 0;
}

void splm_ccsm_init_invalid(splm_ccsm* sm)
{
    sm->val = 0;
    sm->rowidx = 0;
    sm->colptr = 0;
    sm->nr = sm->nc = sm->nnz = -1;
    sm->cm_owner = 0;
    sm->cm_common = 0;
}

/* allocate a sparse CCS matrix */
SuiteSparse_long splm_ccsm_alloc(splm_ccsm* sm, SuiteSparse_long nr, SuiteSparse_long nc, SuiteSparse_long nnz)
{
    sm->val = (double*)malloc(nnz * sizeof(double));
    sm->rowidx = (SuiteSparse_long*)malloc(nnz * sizeof(SuiteSparse_long));
    sm->colptr = (SuiteSparse_long*)malloc((nc + 1) * sizeof(SuiteSparse_long));
    if (!sm->val || !sm->rowidx || !sm->colptr)
    {
        if (sm->val) { free(sm->val); sm->val = 0; }
        if (sm->rowidx) { free(sm->rowidx); sm->rowidx = 0; }
        if (sm->colptr) { free(sm->colptr); sm->colptr = 0; }
        sm->nr = sm->nc = sm->nnz = -1;
        return -1;
    }
    sm->nr = nr;
    sm->nc = nc;
    sm->nnz = nnz;
    sm->cm_owner = 0;
    sm->cm_common = 0;
    return 0;
}

/* free a sparse CCS matrix (but NOT the cholmod part if any)*/
void splm_ccsm_free(splm_ccsm* sm)
{
    if (sm->val) { free(sm->val); sm->val = 0; }
    if (sm->rowidx) { free(sm->rowidx); sm->rowidx = 0; }
    if (sm->colptr) { free(sm->colptr); sm->colptr = 0; }
    sm->nr = sm->nc = sm->nnz = -1;
}

/* returns the index of the (i, j) element. No bounds checking! */
SuiteSparse_long splm_ccsm_elmidx(splm_ccsm* sm, SuiteSparse_long i, SuiteSparse_long j)
{
    register SuiteSparse_long low, high, mid, * Rowidx, diff;

    low = sm->colptr[j];
    high = sm->colptr[j + 1] - 1;
    Rowidx = sm->rowidx;

    /* binary search for finding the element at row i */
    while (low <= high) {
        //if(i<Rowidx[low] || i>Rowidx[high]) return -1; /* not found */

        mid = (low + high) >> 1; //(low+high)/2;
        //mid=low+((high-low)>>1); /* ensures no index overflows */
        diff = i - Rowidx[mid];
        if (diff < 0)
            high = mid - 1;
        else if (diff > 0)
            low = mid + 1;
        else
            return mid;
    }

    return -1; /* not found */
}

/* returns the maximum number of nonzero elements across all columns */
SuiteSparse_long splm_ccsm_col_maxnelms(splm_ccsm* sm)
{
    register SuiteSparse_long j, n, max;

    for (j = sm->nc, max = -1; j-- > 0; )
        if ((n = sm->colptr[j + 1] - sm->colptr[j]) > max) max = n;

    return max;
}

/* returns the number of nonzero elements in col j and
 * fills up the vidxs and iidxs arrays with the val and row
 * indexes of the elements found, respectively.
 * vidxs and iidxs are assumed preallocated and of max. size sm->nr
 */
SuiteSparse_long splm_ccsm_col_elmidxs(splm_ccsm* sm, SuiteSparse_long j, SuiteSparse_long* vidxs, SuiteSparse_long* iidxs)
{
    register SuiteSparse_long i, k;
    SuiteSparse_long low, high, * rowidx = sm->rowidx;

    low = sm->colptr[j];
    high = sm->colptr[j + 1];
    for (i = low, k = 0; i < high; ++i, ++k) {
        vidxs[k] = i;
        iidxs[k] = rowidx[i];
    }

    return k;
}

void splm_crsm_init_invalid(splm_crsm* sm)
{
    sm->val = 0;
    sm->colidx = 0;
    sm->rowptr = 0;
    sm->nr = sm->nc = sm->nnz = -1;
}

/* allocate all fields except values */
SuiteSparse_long splm_crsm_alloc_novalues(splm_crsm* sm, SuiteSparse_long nr, SuiteSparse_long nc, SuiteSparse_long nnz)
{
    sm->nr = nr;
    sm->nc = nc;
    sm->nnz = nnz;

    sm->val = 0;
    sm->colidx = nnz > 0 ? (SuiteSparse_long*)malloc(nnz * sizeof(SuiteSparse_long)) : 0;
    sm->rowptr = (SuiteSparse_long*)malloc((nr + 1) * sizeof(SuiteSparse_long));
    if ((nnz > 0 && !sm->colidx) || !sm->rowptr) {
        if(sm->colidx) { free(sm->colidx); sm->colidx=0; }
        if (sm->rowptr) { free(sm->rowptr); sm->rowptr = 0; }
        sm->nr = sm->nc = sm->nnz = -1;
        return -1;
    }
    return 0;
}

/* allocate val and colidx after allocating rowptr with splm_crsm_alloc_novalues(...,0) */
SuiteSparse_long splm_crsm_alloc_rest(splm_crsm* sm, SuiteSparse_long nnz)
{
   if(sm->nr<0 || sm->nc<0 || 0==sm->rowptr)
      return -1;

   sm->nnz = nnz;

   sm->val = (double*)malloc(nnz * sizeof(double));;
   sm->colidx = (SuiteSparse_long*)malloc(nnz * sizeof(SuiteSparse_long));
   if (!sm->val || !sm->colidx)
   {
      if (sm->val) { free(sm->val); sm->val = 0; }
      if (sm->colidx) { free(sm->colidx); sm->colidx = 0; }
      if (sm->rowptr) { free(sm->rowptr); sm->rowptr = 0; }
      sm->nr = sm->nc = sm->nnz = -1;
      return -1;
   }
   return 0;
}

/* free a sparse CRS matrix */
void splm_crsm_free(splm_crsm* sm)
{
    if (sm->val) { free(sm->val); sm->val = 0; }
    if (sm->colidx) { free(sm->colidx); sm->colidx = 0; }
    if (sm->rowptr) { free(sm->rowptr); sm->rowptr = 0; }
    sm->nr = sm->nc = sm->nnz = -1;
}

splm_ccsm* cholmod_sparse_to_splm_ccsm(cholmod_sparse* cmsp, cholmod_common* cm_common)
{  /* If this function succeeds (returns != 0), you must not call cholmod_free_sparse(cmsp) on destroying.
      Instead you must call splm_ccsm_destruct(ccsm) where ccsm is the pointer returned by 
      cholmod_sparse_to_splm_ccsm). */
    splm_ccsm* sm;
    if (!cmsp || !cmsp->packed || !cmsp->sorted || cmsp->dtype != CHOLMOD_DOUBLE || cmsp->xtype != CHOLMOD_REAL)
    {
        return 0;
    }
    if (0 != (sm = malloc(sizeof(splm_ccsm))))
    {
        sm->nr = cmsp->nrow;
        sm->nc = cmsp->ncol;
        sm->nnz = cmsp->nzmax;
        sm->colptr = (SuiteSparse_long*)cmsp->p;
        sm->rowidx = (SuiteSparse_long*)cmsp->i;
        sm->val = (double*)cmsp->x;
        sm->cm_owner = cmsp;
        sm->cm_common = cm_common;
    }
    return sm;
}

void splm_ccsm_destruct(splm_ccsm* sm)
{
    if (sm)
    {
        if (sm->cm_owner)
        {
            cholmod_l_free_sparse(&sm->cm_owner, sm->cm_common);
        }
        else
        {
            splm_ccsm_free(sm);
        }
        free(sm);
    }
}

cholmod_sparse* cholmod_sparse_mirror_from_ccsm(splm_ccsm* sm)
{   /* You must not call cholmod_free_sparse() for the maxtix returned by this function. */
    if (!sm)
    {
        return 0;
    }
    sm->static_cm_mirror.nrow = sm->nr;
    sm->static_cm_mirror.ncol = sm->nc;
    sm->static_cm_mirror.nzmax = sm->nnz;
    sm->static_cm_mirror.x = sm->val;
    sm->static_cm_mirror.p = sm->colptr;
    sm->static_cm_mirror.i = sm->rowidx;
    sm->static_cm_mirror.nz = sm->static_cm_mirror.z = 0;
    sm->static_cm_mirror.stype = 0; // unsymmetric matrix
    sm->static_cm_mirror.itype = CHOLMOD_LONG;
    sm->static_cm_mirror.xtype = CHOLMOD_REAL;
    sm->static_cm_mirror.dtype = CHOLMOD_DOUBLE;
    sm->static_cm_mirror.sorted = sm->static_cm_mirror.packed = 1;
    return &(sm->static_cm_mirror);
}

SuiteSparse_long splm_SuiteSparseQR
(
    // inputs, not modified
    int ordering,           // all, except 3:given treated as 0:fixed
    double tol,             // columns with 2-norm <= tol are treated as zero
    SuiteSparse_long econ,  // number of rows of C and R to return; a value
                            // less than the rank r of A is treated as r, and
                            // a value greater than m is treated as m.
                            // That is, e = max(min(m,econ),rank(A)) gives the
                            // number of rows of C and R, and columns of C'.

    int getCTX,             // if 0: return Z = C of size econ-by-bncols
                            // if 1: return Z = C' of size bncols-by-econ
                            // if 2: return Z = X of size econ-by-bncols

    splm_ccsm* A,      // m-by-n sparse matrix

    // B is either sparse or dense.  If Bsparse is non-NULL, B is sparse and
    // Bdense is ignored.  If Bsparse is NULL and Bdense is non-NULL, then B is
    // dense.  B is not present if both are NULL.
    splm_ccsm* Bsparse,    // B is m-by-bncols
    cholmod_dense* Bdense,

    // output arrays, neither allocated nor defined on input.

    // Z is the matrix C, C', or X, either sparse or dense.  If p_Zsparse is
    // non-NULL, then Z is returned as a sparse matrix.  If p_Zsparse is NULL
    // and p_Zdense is non-NULL, then Z is returned as a dense matrix.  Neither
    // are returned if both arguments are NULL.
    splm_ccsm** p_Zsparse,
    cholmod_dense** p_Zdense,

    splm_ccsm** p_R,   // the R factor
    SuiteSparse_long** p_E,        // size n; fill-reducing ordering of A.
    splm_ccsm** p_H,   // the Householder vectors (m-by-nh)
    SuiteSparse_long** p_HPinv,    // size m; row permutation for H
    cholmod_dense** p_HTau, // size 1-by-nh, Householder coefficients

    // workspace and parameters
    cholmod_common* cc
)
{
    cholmod_sparse* p_cmZsparse = 0;
    cholmod_sparse* p_cmR = 0;
    cholmod_sparse* p_cmH = 0;

    SuiteSparse_long rank = SuiteSparseQR_C(ordering, tol, econ, getCTX,
        cholmod_sparse_mirror_from_ccsm(A),
        cholmod_sparse_mirror_from_ccsm(Bsparse), Bdense,
        p_Zsparse ? (&p_cmZsparse) : 0, p_Zdense,
        p_R ? (&p_cmR) : 0, p_E,
        p_H ? (&p_cmH) : 0, p_HPinv, p_HTau, cc);

    if(cc->useGPU && CHOLMOD_GPU_PROBLEM == cc->status)
    {
        cc->useGPU = 0;
        rank = SuiteSparseQR_C(ordering, tol, econ, getCTX,
            cholmod_sparse_mirror_from_ccsm(A),
            cholmod_sparse_mirror_from_ccsm(Bsparse), Bdense,
            p_Zsparse ? (&p_cmZsparse) : 0, p_Zdense,
            p_R ? (&p_cmR) : 0, p_E,
            p_H ? (&p_cmH) : 0, p_HPinv, p_HTau, cc);
    }

    if (cc->status < CHOLMOD_OK ||
        (p_Zsparse && !p_cmZsparse) || (p_R && !(p_cmR)) || (p_H && !(p_cmH)))
    {
        rank = -1;
    }
    else if (p_cmZsparse && 0 == (*p_Zsparse = cholmod_sparse_to_splm_ccsm(p_cmZsparse, cc)))
    {
        rank = -1;
    }
    else if (p_cmR && 0 == (*p_R = cholmod_sparse_to_splm_ccsm(p_cmR, cc)))
    {
        rank = -1;
    }
    else if (p_H && 0 == (*p_H = cholmod_sparse_to_splm_ccsm(p_cmH, cc)))
    {
        rank = -1;
    }

    if (rank < 0)
    {
        if (p_cmZsparse) cholmod_l_free_sparse(&p_cmZsparse, cc);
        if (p_Zsparse && *p_Zsparse) free(*p_Zsparse);

        if (p_cmR) cholmod_l_free_sparse(&p_cmR, cc);
        if (p_R && *p_R) free(*p_R);

        if (p_cmH) cholmod_l_free_sparse(&p_cmH, cc);
        if (p_H && *p_H) free(*p_H);
    }

    return rank;
}

#ifdef DEBUG_PRINT_MATRIX_VECTOR
void print_matrix_cmd(char* str, cholmod_dense* Md)
{
    printf("%s :\n", str);
    int i, j;
    for (i = 0; i < Md->nrow; i++)
    {
        for (j = 0; j < Md->ncol; j++)
            printf("%.16f  ", ((double*)Md->x)[i + Md->nrow * j]);
        printf("\n");
    }
    printf("\n");
}

void print_vector_cmd(char* str, cholmod_dense* Md)
{
    printf("%s :\n", str);
    int i;
    for (i = 0; i < Md->nrow; i++)
    {
        printf("%.16f  ", ((double*)Md->x)[i]);
    }
    printf("\n");
}

void print_matrix_cms(char* str, cholmod_sparse* Ms, cholmod_common* c)
{
    cholmod_dense* Md = cholmod_l_sparse_to_dense(Ms, c);
    print_matrix_cmd(str, Md);
    cholmod_l_free_dense(&Md, c);
}

void print_matrix_s(char* str, splm_ccsm* Ms)
{
    printf("%s :\n", str);
    SuiteSparse_long i, j, idx;
    for (i = 0; i < Ms->nr; i++)
    {
        for (j = 0; j < Ms->nc; j++)
        {
            idx = splm_ccsm_elmidx(Ms, i, j);
            printf("%.16f  ", idx >= 0 ? Ms->val[idx] : 0);
        }
        printf("\n");
    }
    printf("\n");
}
#endif

/* finite difference approximation to the Jacobian of func
 * using either forward or central differences.
 * The structure of the Jacobian is assumed known.
 * Uses the strategy described in Nocedal-Wright, ch. 7, pp. 169.
 */
static SuiteSparse_long splm_intern_fdif_jac(
    double* p,              /* input: current parameter estimate, nvarsx1 */
    splm_ccsm* jac,         /* output: CCS array storing approximate Jacobian, nobsxnvars */
    int nobs,
    int mvars,
    double epsfcn,
    double mindeltax,
    int (*func)(int n_obs, int m_vars, double* x, double* fvec, int* iflag),
    int forw,  /* 1: forward differences, 0: central differences */
    int *nfeval,        /* number of func evaluations for computing Jacobian */
    int *iflag)
{
    register SuiteSparse_long i, j, jj, k;
    register double d;
    SuiteSparse_long ii, m, * jcol = 0, * varlist = 0, * coldone = 0;
    SuiteSparse_long* vidxs = 0, * ridxs = 0;
    double* tmpd = 0;
    double* p0 = 0, * hx = 0, * hxx = 0;
    const double eps = sqrt(fmax(epsfcn, MACHEP));
    double scl;
    SuiteSparse_long ret = -1;

    if (0 == (p0 = (double*)malloc(mvars * sizeof(double)))) goto freeall;
    if (0 == (hx = (double*)malloc(nobs * sizeof(double)))) goto freeall;
    if (0 == (hxx = (double*)malloc(nobs * sizeof(double)))) goto freeall;

    if (0 == (jcol = (SuiteSparse_long*)malloc(nobs * sizeof(SuiteSparse_long)))) goto freeall; /* keeps track of measurements influenced by the set of variables currently in "varlist" below */
    for (i = 0; i < nobs; ++i) jcol[i] = -1;

    k = splm_ccsm_col_maxnelms(jac);
    if (0 == (vidxs = (SuiteSparse_long*)malloc(2 * k * sizeof(SuiteSparse_long)))) goto freeall;
    ridxs = vidxs + k;

    if (0 == (varlist = (SuiteSparse_long*)malloc(mvars * sizeof(SuiteSparse_long)))) goto freeall; /* stores indices of J's columns which are computed with the same "func" call */
    if (0 == (coldone = (SuiteSparse_long*)malloc(mvars * sizeof(SuiteSparse_long)))) goto freeall; /* keeps track of J's columns which have been already computed */
    memset(coldone, 0, mvars * sizeof(SuiteSparse_long)); /* initialize to zero */

    if (0 == (tmpd = (double*)malloc(mvars * sizeof(double)))) goto freeall;

    if (forw)
    {
        (*func)(nobs, mvars, p, hx, iflag); ++(*nfeval); // hx=f(p)
    }

    for (j = 0; j < mvars; ++j)
    {
        p0[j] = p[j];
    }

    for (j = 0; j < mvars; ++j)
    {
        if (coldone[j]) continue; /* column j already computed */

        k = splm_ccsm_col_elmidxs(jac, j, vidxs, ridxs);
        for (i = 0; i < k; ++i) jcol[ridxs[i]] = j;
        varlist[0] = j; m = 1; coldone[j] = 1;

        for (jj = j + 1; jj < mvars; ++jj)
        {
            if (coldone[jj]) continue; /* column jj already computed */

            k = splm_ccsm_col_elmidxs(jac, jj, vidxs, ridxs);
            for (i = 0; i < k; ++i)
                if (jcol[ridxs[i]] != -1) goto nextjj;

            if (0 == k) { coldone[jj] = 1; continue; } /* all zeros column, ignore */

            /* column jj does not clash with previously considered ones, mark it */
            for (i = 0; i < k; ++i) jcol[ridxs[i]] = jj;
            varlist[m++] = jj; coldone[jj] = 1;

        nextjj:
            continue;
        }

        for (k = 0; k < m; ++k)
        {
            /* determine d=max(SPLM_DELTA_SCALE*|p[varlist[k]]|, delta), see HZ */
            d = eps * p[varlist[k]]; // force evaluation
            d = fabs(d);
            if (d < mindeltax) d = mindeltax;
            if (!forw) d *= 0.5;
            if (0 == d) d = eps;

            tmpd[varlist[k]] = d;
            p[varlist[k]] += d;
        }

        (*func)(nobs, mvars, p, hxx, iflag); ++(*nfeval); // hxx=f(p+d)

        if (forw)
        {
            for (k = 0; k < m; ++k)
                p[varlist[k]] = p0[varlist[k]]; /* restore */

            scl = 1.0;
        }
        else
        {   // central
            for (k = 0; k < m; ++k)
                p[varlist[k]] -= 2 * tmpd[varlist[k]];

            (*func)(nobs, mvars, p, hx, iflag); ++(*nfeval); // hx=f(p-d)

            for (k = 0; k < m; ++k)
                p[varlist[k]] = p0[varlist[k]]; /* restore */

            scl = 0.5; // 1./2.
        }

        for (k = 0; k < m; ++k)
        {
            d = tmpd[varlist[k]];
            d = scl / d; /* invert so that divisions can be carried out faster as multiplications */

            jj = splm_ccsm_col_elmidxs(jac, varlist[k], vidxs, ridxs);
            for (i = 0; i < jj; ++i)
            {
                ii = ridxs[i];
                jac->val[vidxs[i]] = (hxx[ii] - hx[ii]) * d;
                jcol[ii] = -1; /* restore */
            }
        }
    }
    ret = 0;

freeall:
    if (p0) free(p0);
    if (hx) free(hx);
    if (hxx) free(hxx);
    if (tmpd) free(tmpd);
    if (coldone) free(coldone);
    if (varlist) free(varlist);
    if (vidxs) free(vidxs);
    if (jcol) free(jcol);

    return ret;
}

cholmod_dense* dense_wrapper
(
    cholmod_dense* X,
    SuiteSparse_long nrow,
    SuiteSparse_long ncol,
    double* Xx
)
{
    X->xtype = CHOLMOD_REAL;
    X->nrow = nrow;
    X->ncol = ncol;
    X->d = nrow;           // leading dimension = nrow
    X->nzmax = nrow * ncol;
    X->x = Xx;
    X->z = 0;              // ZOMPLEX case not supported
    X->dtype = CHOLMOD_DOUBLE;
    return X;
}

// =============================================================================
// === Rsolve ==================================================================
// =============================================================================

// Solve R*Y = X for Y and write Y back to X

SuiteSparse_long Rsolve
(
    // R is at n-by-n or bigger, upper triangular with zero-free diagonal
    // Use only the left, upper n-by-n submatrix of R
    // X has memory for at least n doubles.
    SuiteSparse_long n,
    cholmod_sparse* R,
    double* X,       // X is n-by-nx, leading dimension n, overwritten with solution
    SuiteSparse_long nx, // nx==1 if X is a column vector
    cholmod_common* cc
)
{
    SuiteSparse_long* Rp = (SuiteSparse_long*)R->p;
    SuiteSparse_long* Ri = (SuiteSparse_long*)R->i;
    double* Rx = (double*)R->x;
    double rjj;
    SuiteSparse_long k, j, p;

    if (!R->packed || !R->sorted || R->dtype != CHOLMOD_DOUBLE || R->xtype != CHOLMOD_REAL)
    {
        return -1;
    }
    if ((SuiteSparse_long)R->ncol < n || (SuiteSparse_long)R->nrow < n)
    {
        return -1;
    }

    // check the diagonal
    for (j = 0; j < n; j++)
    {
        if (Rp[j + 1] <= Rp[j] || Ri[Rp[j + 1] - 1] != j)
        {
            // Rsolve: R not upper triangular with zero-free diagonal
            return -1;
        }
    }

    // do the backsolve
    for (k = 0; k < nx; k++)
    {
        for (j = n; j > n; )
        {
            X[--j] = ((double)0);
        }
        for (j = n; 0 != j; )
        {
            rjj = Rx[Rp[j] - 1];
            if (((double)0) == rjj)
            {
                // Rsolve: R has an explicit zero on the diagonal
                return -1;
            }
            X[--j] /= rjj;
            for (p = Rp[j]; p + 1 < Rp[j + 1]; p++)
            {
                X[Ri[p]] -= Rx[p] * X[j];
            }
        }
        X += n;
    }

    return 0;
}

// =============================================================================
// === RTsolve =================================================================
// =============================================================================

// Solve transpose(R)*Y = X for Y and write Y back to X

SuiteSparse_long RTsolve
(
    // R is at n-by-n or bigger, upper triangular with zero-free diagonal
    // Use only the left, upper n-by-n submatrix of R
    // X has memory for at least n doubles.
    SuiteSparse_long n,
    cholmod_sparse* R,
    double* X,       // X is n-by-nx, leading dimension n, overwritten with solution
    SuiteSparse_long nx, // nx==1 if X is a column vector
    cholmod_common* cc
)
{
    SuiteSparse_long i, j, k, l, p;
    SuiteSparse_long* rowidx = R->i, * colptr = R->p;
    SuiteSparse_long* colidx, * rowptr;
    SuiteSparse_long* rowcounts; // counters for the number of nonzeros in each row
    double* val;
    double rjj;

    if (!R->packed || !R->sorted || R->dtype != CHOLMOD_DOUBLE || R->xtype != CHOLMOD_REAL)
    {
        return -1;
    }
    if ((SuiteSparse_long)R->ncol < n || (SuiteSparse_long)R->nrow < n)
    {
        return -1;
    }

    // check the diagonal
    for (j = 0; j < n; j++)
    {
        if (colptr[j + 1] <= colptr[j] || rowidx[colptr[j + 1] - 1] != j)
        {
            // RTsolve: R not upper triangular with zero-free diagonal
            return -1;
        }
    }

    if (0 == (rowcounts = (SuiteSparse_long*)malloc(n * sizeof(SuiteSparse_long))))
    {
        return -1;
    }

    if (0 == (val = (double*)malloc(R->nzmax * sizeof(double))))
    {
        free(rowcounts);
        return -1;
    }
    if (0 == (colidx = (SuiteSparse_long*)malloc(R->nzmax * sizeof(SuiteSparse_long))))
    {
        free(rowcounts);
        free(val);
        return -1;
    }
    if (0 == (rowptr = (SuiteSparse_long*)malloc((n + 1) * sizeof(SuiteSparse_long))))
    {
        free(rowcounts);
        free(val);
        free(colidx);
        return -1;
    }

    /* 1st pass: count #nonzeros in each row */

    for (j = 0; j < n; j++)
        rowcounts[j] = 0;

    for (i = colptr[n]; i-- > 0; )
        ++(rowcounts[rowidx[i]]);

    /* 2nd pass: copy every nonzero to its right position into the CRS structure */
    for (i = k = 0; i < n; ++i) {
        rowptr[i] = k;
        k += rowcounts[i];
        rowcounts[i] = 0; // clear to avoid separate loop below
    }
    rowptr[n] = R->nzmax;

    /* rowcounts[i] will count the #nonzeros in row i seen before the current column */

    for (j = 0; j < n; ++j) {
        for (i = colptr[j]; i < colptr[j + 1]; ++i) {
            l = rowidx[i];
            k = rowptr[l] + (rowcounts[l]++);
            colidx[k] = j;
            val[k] = ((double*)R->x)[i];
        }
    }

    // do the forward solve
    for (k = 0; k < nx; k++)
    {
        for (j = 0; j < n; j++)
        {
            rjj = val[rowptr[j]];
            if (((double)0) == rjj)
            {
                // RTsolve: R has an explicit zero on the diagonal
                free(rowcounts);
                free(val);
                free(colidx);
                free(rowptr);
                return -1;
            }
            X[j] /= rjj;

            for (p = rowptr[j]; ++p < rowptr[j + 1]; )
            {
                X[colidx[p]] -= val[p] * X[j];
            }
        }
        while (j < n)
        {
            X[j++] = ((double)0);
        }
        X += n;
    }

    free(rowcounts);
    free(val);
    free(colidx);
    free(rowptr);
    return 0;
}


/* expand_jacobi_with_damping_matrix(): Expands the matrix jac_ccs by appending a diagonal matrix below
*  that has diagonal elements damping_factors[]. returns 0 is success and -1 otherwise.
*  The matrix jac_ccs passed to expand_jacobi_with_damping_matrix() must not have been "mirrored" from a
*  cholmod_sparse matrix via the function cholmod_sparse_to_splm_ccsm().
*/

static SuiteSparse_long expand_jacobi_with_damping_matrix(splm_ccsm* jac_ccs, double* damping_factors)
{
    SuiteSparse_long i, j1, j2;
    SuiteSparse_long nc = jac_ccs->nc;
    SuiteSparse_long nr = jac_ccs->nr;
    SuiteSparse_long* rowidx = 0;
    double* val = 0;

    if (0 == jac_ccs->val || jac_ccs->cm_owner)
    {
        return -1;
    }

    if (0 == (rowidx = (SuiteSparse_long*)realloc(jac_ccs->rowidx, (jac_ccs->nnz + nc) * sizeof(SuiteSparse_long))))
    {
        goto error_free_all;
    }
    jac_ccs->rowidx = rowidx;

    if (0 == (val = (double*)realloc(jac_ccs->val, (jac_ccs->nnz + nc) * sizeof(double))))
    {
        goto error_free_all;
    }
    jac_ccs->val = val;

    for (i = nc; --i >= 0; )
    {
        j2 = jac_ccs->colptr[i + 1];
        j1 = jac_ccs->colptr[i];
        jac_ccs->val[j2 + i] = (0 == damping_factors) ? 0 : damping_factors[i];
        jac_ccs->rowidx[j2 + i] = nr + i;
        while (--j2 >= j1)
        {
            jac_ccs->val[j2 + i] = jac_ccs->val[j2];
            jac_ccs->rowidx[j2 + i] = jac_ccs->rowidx[j2];
        }
        jac_ccs->colptr[i + 1] += i + 1;
    }

    jac_ccs->nr += nc;
    jac_ccs->nnz += nc;

    return 0;

error_free_all:
    if (jac_ccs->colptr) { free(jac_ccs->colptr); jac_ccs->colptr = 0; }
    if (jac_ccs->rowidx) { free(jac_ccs->rowidx); jac_ccs->rowidx = 0; }
    if (jac_ccs->val) { free(jac_ccs->val); jac_ccs->val = 0; }
    jac_ccs->nr = jac_ccs->nc = jac_ccs->nnz = -1;
    return -1;
}

/* remove_jacobi_damping_matrix(): removes the damping matrix that has been added below
*  via an earlier call of expand_jacobi_with_damping_matrix().
*/

static SuiteSparse_long remove_jacobi_damping_matrix(splm_ccsm* jac_ccs)
{
    SuiteSparse_long i, j1, j2;
    SuiteSparse_long nc = jac_ccs->nc;
    SuiteSparse_long* rowidx = 0;
    double* val = 0;

    if (0 == jac_ccs->val || jac_ccs->cm_owner || jac_ccs->nnz < nc)
    {
        goto error_free_all;
    }

    for (i = 0; i < nc; i++)
    {
        jac_ccs->colptr[i + 1] -= i + 1;
        j2 = jac_ccs->colptr[i + 1];
        j1 = jac_ccs->colptr[i];
        while (j1 < j2)
        {
            jac_ccs->val[j1] = jac_ccs->val[j1 + i];
            jac_ccs->rowidx[j1] = jac_ccs->rowidx[j1 + i];
            j1++;
        }
    }

    if (0 == (rowidx = (SuiteSparse_long*)realloc(jac_ccs->rowidx, (jac_ccs->nnz - nc) * sizeof(SuiteSparse_long))))
    {
        goto error_free_all;
    }
    jac_ccs->rowidx = rowidx;

    if (0 == (val = (double*)realloc(jac_ccs->val, (jac_ccs->nnz - nc) * sizeof(double))))
    {
        goto error_free_all;
    }
    jac_ccs->val = val;

    jac_ccs->nr -= nc;
    jac_ccs->nnz -= nc;

    return 0;

error_free_all:
    if (jac_ccs->colptr) { free(jac_ccs->colptr); jac_ccs->colptr = 0; }
    if (jac_ccs->rowidx) { free(jac_ccs->rowidx); jac_ccs->rowidx = 0; }
    if (jac_ccs->val) { free(jac_ccs->val); jac_ccs->val = 0; }
    jac_ccs->nr = jac_ccs->nc = jac_ccs->nnz = -1;
    return -1;
}

/* set_damping_matrix_diag(): changes the diagonal elements of the diagonal damping matrix
*  to diag[] that has been added below via an earlier call of expand_jacobi_with_damping_matrix().
*/

static void set_damping_matrix_diag(splm_ccsm* jac_ccs, double* diag)
{
    SuiteSparse_long* rowidx = jac_ccs->rowidx, * colptr = jac_ccs->colptr;
    SuiteSparse_long i;

    for (i = jac_ccs->nc; 0 != i; i--)
    {
        if (colptr[i] <= colptr[i - 1])
        {
            return;  /* Error */
        }
        jac_ccs->val[colptr[i] - 1] = (0 == diag) ? 0 : diag[i - 1];
    }
}

/* splm_lmpar(): similar to minpack's lmpar() subroutine except that sparse matrices are used.
*  Think the jacobi matrix A (or fjac in lmdif_sparse()) has been expanded below with a diagonal
*  matrix containing the damping terms diag[]. In minpack's lmpar() the QR factorization of this
*  expanded matrix is calculated by updating the QR factorization that has been calculated from
*  the jacobi without the damping matrix. Here in splm_lmpar() the QR factorization of the 
*  expanded jacobi is calculated from scratch. In some applications this is probably not slower
*  than updating because the R matrix may have a higher percentage of nonzero elements than the
*  jacobi matrix and so an update using R may be expensive.
*/

SuiteSparse_long splm_lmpar(SuiteSparse_long m, splm_ccsm* A, splm_ccsm* R, SuiteSparse_long* perm, double* diag,
                            cholmod_dense* b, cholmod_dense* qtb, double delta, double* par, double* x, cholmod_common* cc, int64_t force_rank_estimation)
{
    static double cm_one[2] = { 1,0 }, cm_zero[2] = { 0,0 };

    SuiteSparse_long iter, j, k, nsing;
    double dxnorm, fp, gnorm, parc, parl, paru;
    double temp;
    double* wa1 = 0;
    double* wa2 = 0;
    cholmod_dense* RTqtb = 0;
    const double zero = 0.0;
    const double p1 = 0.1;
    const double p001 = 0.001;
    splm_ccsm* R2 = 0;
    cholmod_dense* cmx = 0;
    cholmod_dense* b_exp = 0;
    SuiteSparse_long* perm2 = 0;
    SuiteSparse_long ret = -1;
    SuiteSparse_long must_remove_jacobi_damping_matrix = 0;

    iter = 0;

    /*
    *     compute and store in x the gauss-newton direction. if the
    *     jacobian is rank-deficient, obtain a least squares solution.
    */
    if (0 == (wa1 = (double*)malloc(sizeof(double) * m)))
    {
        goto freeall;
    }
    if (0 == (wa2 = (double*)malloc(sizeof(double) * m)))
    {
        goto freeall;
    }

    nsing = m;
    for (j = 0; j < m; j++)
    {
        wa1[j] = ((double*)qtb->x)[j];
        if (nsing == m && (R->colptr[j + 1] <= R->colptr[j] || R->rowidx[R->colptr[j + 1] - 1] != j || zero == R->val[R->colptr[j + 1] - 1]))
            nsing = j;
        if (nsing < m)
            wa1[j] = zero;
    }

    if (nsing >= 1)
    {
        if (Rsolve(nsing, cholmod_sparse_mirror_from_ccsm(R), wa1, 1, cc))
        {
            goto freeall;   /* Error in Rsolve */
        }
    }

    for (j = 0; j < m; j++)
    {
        k = perm[j];
        x[k] = wa1[j];
    }

    // print_vector_C("   x = ", x, m);
    // print_vector_C("   diag = ", diag, m);
    // printf("   delta = %.16f\n", delta);

    /*
    *     evaluate the function at the origin, and test
    *     for acceptance of the gauss-newton direction.
    */
    for (j = 0; j < m; j++)
        wa2[j] = diag[j] * x[j];
    dxnorm = enorm(m, wa2);
    fp = dxnorm - delta;
    // printf("   fp = %.16f\n", fp);
    if (fp <= p1 * delta)
    {
        ret = 0;
        goto freeall;
    }

    /*
    *     if the jacobian is not rank deficient, the newton
    *     step provides a lower bound, parl, for the zero of
    *     the function. otherwise set this bound to zero.
    */
    parl = zero;
    if (nsing >= m)
    {
        for (j = 0; j < m; j++)
        {
            k = perm[j];
            wa1[j] = diag[k] * (wa2[k] / dxnorm);
        }

        if (RTsolve(m, cholmod_sparse_mirror_from_ccsm(R), wa1, 1, cc))
        {
            goto freeall;   /* Error in RTsolve */
        }

        temp = enorm(m, wa1);
        parl = ((fp / delta) / temp) / temp;

    }

    // printf("   parl = %.16f\n", parl);

    /*
    *     calculate an upper bound, paru, for the zero of the function.
    */
    if (0 == (RTqtb = cholmod_l_zeros(m, 1, CHOLMOD_REAL, cc)))
    {
        goto freeall;   /* Error in cholmod_l_zeros */
    }
    if (0 == cholmod_l_sdmult(cholmod_sparse_mirror_from_ccsm(R), 1, cm_one, cm_zero, qtb, RTqtb, cc))
    {
        goto freeall;   /* Error in cholmod_l_sdmult */
    }

    for (j = 0; j < m; j++)
    {
        k = perm[j];
        wa1[j] = ((double*)RTqtb->x)[j] / diag[k];
    }
    cholmod_l_free_dense(&RTqtb, cc); RTqtb = 0;

    gnorm = enorm(m, wa1);
    paru = gnorm / delta;
    if (zero == paru)
        paru = DWARF / fmin(delta, p1);

    // printf("   paru = %.16f\n", paru);

    /*
    *     if the input par lies outside of the interval (parl,paru),
    *     set par to the closer endpoint.
    */
    *par = fmax(*par, parl);
    *par = fmin(*par, paru);
    if (zero == *par)
        *par = gnorm / dxnorm;

    if (expand_jacobi_with_damping_matrix(A, 0))
    {
        goto freeall;
    }
    must_remove_jacobi_damping_matrix = 1;

    if (0 == (b_exp = cholmod_l_zeros(b->nrow + m, 1, CHOLMOD_REAL, cc)))
    {
        goto freeall;
    }
    for (j = b->nrow; j > 0; )
    {
        --j;
        ((double*)b_exp->x)[j] = ((double*)b->x)[j];
    }

    /*
    *     beginning of an iteration.
    */
    for (iter = 1; ; iter++)
    {
        // printf("   ##### iter = %lld #####\n", iter);
        /*
        *	 evaluate the function at the current value of par.
        */
        // f("   par = %.16f\n", *par);
        if (zero == *par)
            *par = fmax(DWARF, p001 * paru);
        temp = sqrt(*par);
        for (j = 0; j < m; j++)
            wa1[j] = temp * diag[j];
        set_damping_matrix_diag(A, wa1);

        //print_matrix_s("   A_exp = ", A);
        //print_vector_cmd("   b_exp = ", b_exp);

        const double tol_with_rank_estimation = -2;     /* tol=-2 means rank estimation; necessary for case of rank deficient jacobi but SuiteSparseQR cannot use GPU */
        const double tol_without_rank_estimation = -1;  /* -1: do not estimate rank, so SuiteSparseQR() can use the GPU */
        //printf("start splm_SuiteSparseQR %s rank estimation\n", (force_rank_estimation && !cc->useGPU) ? "with" : "without");
        nsing = splm_SuiteSparseQR(SPQR_ORDERING_BEST, (force_rank_estimation && !cc->useGPU) ? tol_with_rank_estimation : tol_without_rank_estimation,
                                   m, 2, A, 0, b_exp, 0, &cmx, &R2, &perm2, 0, 0, 0, cc);
        //printf("finished splm_SuiteSparseQR\n");

        if (nsing < 0 || 0 == cmx || 0 == R2 || 0 == perm2)
        {
            goto freeall;
        }

        //printf("nsing (1) = %d   m = %d\n", nsing, m);
        if(nsing == m)
        {
            for (j = 0; j < m; j++)
            {
                if (R2->colptr[j + 1] <= R2->colptr[j] || R2->rowidx[R2->colptr[j + 1] - 1] != j)
                {
                    //printf("rank = %d   m_vars = %d   j = %d\nR->colptr[j] = %d   R->colptr[j] = %d   R->rowidx[R->colptr[j + 1] - 1] = %d\n", nsing, m, j, R2->colptr[j], R2->colptr[j + 1], R2->rowidx[R->colptr[j + 1] - 1]);
                    nsing = j;
                    break;
                }
            }
        }
        if (nsing != m)
        {
            if(force_rank_estimation || cc->useGPU)
            {
                /* if(cc->useGPU)            ==> splm_SuiteSparseQR() already called without rank estimation, but failed */
                /* if(force_rank_estimation) ==> means that the user doesn't want without rank estimation */
                goto freeall;
            }
            // ssplm_SuiteSparseQR() with rank estimation failed, so try splm_SuiteSparseQR() without rank estimation
            splm_ccsm_destruct(R2); R2 = 0;
            cholmod_l_free_dense(&cmx, cc); cmx = 0;
            cholmod_l_free(m, sizeof(SuiteSparse_long), perm2, cc); perm2 = 0;

            //printf("start splm_SuiteSparseQR without rank estimation\n");
            nsing = splm_SuiteSparseQR(SPQR_ORDERING_BEST, tol_without_rank_estimation, m, 2, A, 0, b_exp, 0, &cmx, &R2, &perm2, 0, 0, 0, cc);
            //printf("finished splm_SuiteSparseQR\n");

            if (nsing == m)
            {
                for (j = 0; j < m; j++)
                {
                    if (R2->colptr[j + 1] <= R2->colptr[j] || R2->rowidx[R2->colptr[j + 1] - 1] != j)
                    {
                        nsing = j;
                        break;
                    }
                }
            }

            if (nsing != m || 0 == cmx || 0 == R2 || 0 == perm2)
            {
                goto freeall;
            }
        }
        //print_matrix_s("A = ", A);
        //print_vector_cmd("b_exp = ", b_exp);
        //print_vector_cmd("   x = ", cmx);
        //print_vector_cmd("R2 = ", R2);

        //print_vector_C("   diag = ", diag, m);

        for (j = 0; j < m; j++)
            wa2[j] = diag[j] * ((double*)cmx->x)[j];
        dxnorm = enorm(m, wa2);
        temp = fp;
        fp = dxnorm - delta;

        // printf("   fp = %.16f\n", fp);

        /*
        *	 if the function is small enough, accept the current value
        *	 of par. also test for the exceptional cases where parl
        *	 is zero or the number of iterations has reached 10.
        */
        if (10 == iter)
        {
            break;
        }

        if ((fabs(fp) <= p1 * delta)
            || ((zero == parl) && (fp <= temp) && (temp < zero)))
        {
            break;
        }
        /*
        *	 compute the newton correction.
        */
        for (j = 0; j < m; j++)
        {
            k = perm2[j];
            wa1[j] = diag[k] * (wa2[k] / dxnorm);
        }
        //print_vector_C("wa1 = ", diag, m);

        if (RTsolve(m, cholmod_sparse_mirror_from_ccsm(R2), wa1, 1, cc))
        {
            goto freeall;   /* Error in RTsolve */
        }

        temp = enorm(m, wa1);
        parc = ((fp / delta) / temp) / temp;
        /*
        *	 depending on the sign of the function, update parl or paru.
        */
        if (fp > zero)
            parl = fmax(parl, *par);
        if (fp < zero)
            paru = fmin(paru, *par);
        /*
        *	 compute an improved estimate for par.
        */
        *par = fmax(parl, *par + parc);
        /*
        *	 end of an iteration.
        */

        splm_ccsm_destruct(R2); R2 = 0;
        cholmod_l_free_dense(&cmx, cc); cmx = 0;
        cholmod_l_free(m, sizeof(SuiteSparse_long), perm2, cc); perm2 = 0;
    }

    for (j = 0; j < m; j++)
    {
        x[j] = ((double*)cmx->x)[j];
    }
    ret = 0;

freeall:
    if (0 == iter)
    {
        *par = zero;
    }

    if (must_remove_jacobi_damping_matrix)
    {
        if (remove_jacobi_damping_matrix(A))
            ret = -1;
    }

    if (R2) splm_ccsm_destruct(R2);
    if (cmx) cholmod_l_free_dense(&cmx, cc);
    if (b_exp) cholmod_l_free_dense(&b_exp, cc);
    if (perm2) cholmod_l_free(m, sizeof(SuiteSparse_long), perm2, cc); perm2 = 0;

    if (wa1) free(wa1);
    if (wa2) free(wa2);

    return ret;
}


/*
*     ****************************************************************
*
*     function lmdif_sparse
* 
*     similar to minpack's subroutine lmdif except that sparse matrix operations are
*     used.
*
*     the purpose of lmdif_sparse is to minimize the sum of the squares of
*     n_obs nonlinear functions in m_vars variables by a modification of
*     the levenberg-marquardt algorithm. the user must provide a
*     function which calculates the nonlinear functions. the jacobian is
*     then calculated by a forward- or central-difference approximation.
*
*     the function statement is
*
*  int lmdif_sparse(int n_obs, int m_vars,
*     int(*fcn)(int n_obs, int m_vars, double* x, double* fvec, int* iflag),
*     int calculateJacobian(int n_obs, int m_vars, double* x, splm_crsm* jac, int* nfeval, int* iflag),
*     double *x, double *fvec,
*     double ftol, double xtol, double gtol,
*     int maxfev, double epsfcn, double mindeltax, int64_t forward_diff,
*     double *diag,
*     int mode, double factor,
*     int force_rank_estimation_1,
*     int force_rank_estimation_2,
*     int nprint,
*     int* nfev)
*
*     where
*
*	fcn is the name of the user-supplied function which
*	  calculates the nonlinear functions whose sum of squares shall be minimized.
*    fcn must be defined in the user calling program, and should be written as follows.
*
*    int(*fcn)(int n_obs, int m_vars, double *x, double *fvec, int* iflag)
*	  ----------
*	  calculate the functions at x and
*	  return this vector in fvec.
*	  ----------
*
*	  the value of iflag should not be changed by fcn unless
*	  the user wants to terminate execution of lmdif.
*	  in this case set iflag to a negative integer.
*
*  int calculateJacobian(int n_obs, int m_vars, double* x, splm_crsm* jac, int* nfeval, int* iflag)
*    name of the user-supplied function which calculate the numerical values of the jacobian, i.e. it must also fill
*    jac->val[].
*
*	n_obs is a positive integer input variable set to the number
*	  of functions.
*
*	m_vars is a positive integer input variable set to the number
*	  of variables. m_vars must not exceed n_obs.
*
*	x is an array of length m_vars. on input x must contain
*	  an initial estimate of the solution vector. on output x
*	  contains the final estimate of the solution vector.
*
*	fvec is an output array of length n_obs which contains
*	  the functions evaluated at the output x. If you do not need
*    these function values, you can pass 0 (NULL, zero pointer)
*    for fvec.
*
*	ftol is a nonnegative input variable. termination
*	  occurs when both the actual and predicted relative
*	  reductions in the sum of squares are at most ftol.
*	  therefore, ftol measures the relative error desired
*	  in the sum of squares.
*
*	xtol is a nonnegative input variable. termination
*	  occurs when the relative error between two consecutive
*	  iterates is at most xtol. therefore, xtol measures the
*	  relative error desired in the approximate solution.
*
*	gtol is a nonnegative input variable. termination
*	  occurs when the cosine of the angle between fvec and
*	  any column of the jacobian is at most gtol in absolute
*	  value. therefore, gtol measures the orthogonality
*	  desired between the function vector and the columns
*	  of the jacobian.
*
*	maxfev is a positive integer input variable. termination
*	  occurs when the number of calls to fcn is at least
*	  maxfev by the end of an iteration.
*
*	epsfcn is an input variable used in determining a suitable
*	  step length for the forward-difference approximation. this
*	  approximation assumes that the relative errors in the
*	  functions are of the order of epsfcn. if epsfcn is less
*	  than the machine precision, it is assumed that the relative
*	  errors in the functions are of the order of the machine
*	  precision.
*
*  mindeltax is an input variable that specifies a minimal absolute
*  step length for the finite-difference approximation of the
*  jacobian. It can be useful if parameters in the array x[] may
*  move near zero or if their initial estimate is zero.
*  For a zero parameter the step length - if
*  calculated relative to the parameter value - would be zero.
*  This can be prevented by choosing a positive value for 'mindeltax'.
*  If the (relative) step length is smaller than mindeltax, it is
*  replaced by mindeltax. If both mindeltax and the relative
*  step length are zero, a step length of sqrt(fmax(epsfcn, MACHEP))
*  is used - which may not be suitable in all cases.
* 
*  forward_diff is an integer input variable. If it is zero,
*  the jacobian is approximated via central differences, otherwise
*  via forward differences.
*
*  force_rank_estimation_1 is an integer input variable. If it is
*  nonzero or if no NVIDIA GPU is used with CUDA, the
*  QR factorization inside lmdif_sparse() via SuiteSparse()
*  is done with rank estimation. Otherwise no rank is estimated.
*
*  force_rank_estimation_2 is an integer input variable. If it is
*  nonzero or if no NVIDIA GPU is used with CUDA, the
*  QR factorization inside splm_lmpar() via SuiteSparse()
*  is done with rank estimation. Otherwise no rank is estimated.
*
*	diag is an array of length m_vars. if mode == 2, diag
*	  must contain positive entries that serve as
*	  multiplicative scale factors for the variables.
*    if mode == 1 (see below), diag is internally set.
*    if mode == 1, a 0 (NULL, zero pointer) may be passed
*    for diag, but otherwise it must point to m_vars doubles.
*
*	mode is an integer input variable. if mode == 1, the
*	  variables will be scaled internally. if mode == 2,
*	  the scaling is specified by the input diag. other
*	  values of mode are equivalent to mode == 1.
*
*	factor is a positive input variable used in determining the
*	  initial step bound. this bound is set to the product of
*	  factor and the euclidean norm of diag*x if nonzero, or else
*	  to factor itself. in most cases factor should lie in the
*	  interval (.1,100.). 100. is a generally recommended value.
*
*	nprint is an integer input variable that enables controlled
*	  printing of iterates if it is positive. in this case,
*	  fcn is called with iflag == 0 at the beginning of the first
*	  iteration and every nprint iterations thereafter and
*	  immediately prior to return, with x and fvec available
*	  for printing. if nprint is not positive, no special calls
*	  of fcn with iflag == 0 are made.
*
*	return value of type int64_t of lmdif_sparse():
*    if the user has terminated execution, the (negative)
*	  value of iflag is returned. see description of fcn. otherwise,
*	  one of the following values is returned:
*
*	  return 0:  improper input parameters
*            OR out of (dynamic) memory
*            OR internal error
*         The value 0 is also returned if force_rank_estimation_2 != 0
*         is passed and the matrix being factorized in splm_lmpar() 
*         has numerically a rank deficit (although in theory it has always
*         full rank because of the expansion by the regular damping matrix).
*
*	  return 1:  both actual and predicted relative reductions
*		    in the sum of squares are at most ftol.
*
*	  return 2:  relative error between two consecutive iterates
*		    is at most xtol.
*
*	  return 3:  conditions for return 1 and return 2 both hold.
*
*	  return 4:  the cosine of the angle between fvec and any
*		    column of the jacobian is at most gtol in
*		    absolute value.
*
*	  return 5:  number of calls to fcn has reached or
*		    exceeded maxfev.
*
*	  return 6:  ftol is too small. no further reduction in
*		    the sum of squares is possible.
*
*	  return 7:  xtol is too small. no further improvement in
*		    the approximate solution x is possible.
*
*	  return 8:  gtol is too small. fvec is orthogonal to the
*		    columns of the jacobian to machine precision.
*
*	nfev is an integer output variable set to the number of calls to fcn.
*	  if it is not needed, you can pass 0 (NULL, zero pointer) for nfev.
*
* 
*     ****************************************************************
*/

int lmdif_sparse(int n_obs, int m_vars,
    int(*fcn)(int n_obs, int m_vars, double *x, double *fvec, int* iflag),
    int (*calculateJacobian)(int n_obs, int m_vars, double *x, splm_crsm* jac, int* nfeval, int* iflag),
    double *x, double *fvec,
    double ftol, double xtol, double gtol,
    int maxfev, double epsfcn, double mindeltax, int forward_diff,
    double *diag,
    int mode, double factor,
    int force_rank_estimation_1,
    int force_rank_estimation_2,
    int nprint,
    int* nfev)
{
    int i, iflag, iter, j, k;
    double actred, delta = 1.0e-4, dirder, fnorm, fnorm1, gnorm;
    double par, pnorm, prered, ratio;
    double temp, temp1, temp2, xnorm = 1.0e-4;
    const double one = 1.0;
    const double p1 = 0.1;
    const double p5 = 0.5;
    const double p25 = 0.25;
    const double p75 = 0.75;
    const double p0001 = 1.0e-4;
    const double zero = 0.0;
    splm_ccsm fjac;
    splm_crsm tmp_crsm;
    SuiteSparse_long rank;
    int info;
    int dummy_nfev;
    int need_free_fvec = (0==fvec);
    int need_free_diag = (0==diag);

    splm_ccsm* R = 0;
    SuiteSparse_long* perm = 0;
    double* wa1 = 0;
    double* wa2 = 0;
    double* wa3 = 0;
    double* wa4 = 0;
    cholmod_common cc;
    cholmod_dense* qtf = 0;
    cholmod_dense* RTqtf = 0;
    cholmod_dense cm_fvec;
    cholmod_dense dxperm;
    cholmod_dense* Rdxperm = 0;

    static double complex_one[2] = { 1, 0 };
    static double complex_zero[2] = { 0, 0 };

    if(0 == nfev)
    {
        nfev = &dummy_nfev;
    }

    iflag = 0;
    *nfev = 0;
    info = 0;   /* for case of: invalid input parameters, out of memory or internal error */

    // print_vector_C("init_x =", x, m_vars);

    splm_ccsm_init_invalid(&fjac);
    splm_crsm_init_invalid(&tmp_crsm);

    /*
    *     check the input parameters for errors.
    */
    if ((m_vars <= 0) || (n_obs < m_vars) || (ftol < zero)
        || (xtol < zero) || (gtol < zero) || (maxfev <= 0)
        || (factor <= zero))
    {
        return 0;   /* do not call cholmod_l_finish(), do not goto freeall */
    }
    if (2 == mode && 0 != diag)
    { /* scaling by diag[] */
        for (j = 0; j < m_vars; j++)
        {
            if (diag[j] <= 0.0)
                return 0;   /* do not call cholmod_l_finish(), do not goto freeall */
        }
    }

    if (0 == cholmod_l_start(&cc))
    {
        return 0;   /* do not call cholmod_l_finish(), do not goto freeall */
    }

    cc.useGPU = 0;
#ifdef WITH_NVIDIA_CUDA_GPU_SUPPORT
    CUcontext cucontext;
    if (CUDA_SUCCESS == cuInit(0) && cudaInitDevice(&cucontext))
    {
        size_t total_mem, available_mem;
        if (CUDA_SUCCESS == cuMemGetInfo(&total_mem, &available_mem) && available_mem > 0)
        {
            cc.gpuMemorySize = available_mem;
            cc.useGPU = 1;
        }
        cudaReleaseDevice(&cucontext);
    }
#endif

    if (0 == (Rdxperm = cholmod_l_zeros(m_vars, 1, CHOLMOD_REAL, &cc)))
    {
        goto freeall;
    }

    if(0 == fvec)
    {
        if (0 == (fvec = (double*)malloc(sizeof(double) * n_obs)))
            goto freeall;
    }
    if (0 == diag)
    {
        if (0 == (diag = (double*)malloc(sizeof(double) * m_vars)))
            goto freeall;
    }
    if (0 == (wa1 = (double*)malloc(sizeof(double) * m_vars)))
        goto freeall;
    if (0 == (wa2 = (double*)malloc(sizeof(double) * m_vars)))
        goto freeall;
    if (0 == (wa3 = (double*)malloc(sizeof(double) * m_vars)))
        goto freeall;
    if (0 == (wa4 = (double*)malloc(sizeof(double) * n_obs)))
        goto freeall;

    /*
    *     evaluate the function at the starting point
    *     and calculate its norm.
    */
    iflag = 1;
    (*fcn)(n_obs, m_vars, x, fvec, &iflag);
    *nfev = 1;
    if (iflag < 0)
        goto freeall;
    fnorm = enorm(n_obs, fvec);
    // printf("fnorm = %.16f\n", fnorm);
    /*
    *     initialize levenberg-marquardt parameter and iteration counter.
    */
    par = zero;

    for (iter = 0; ; iter++)
    {
        /*
        *     beginning of the outer loop.
        */

        // printf("\n\n--------------- iter = %lld -----------------\n\n", iter+1);

        /*
        *	 calculate the jacobian matrix.
        */
        iflag = 2;

        splm_crsm_init_invalid(&tmp_crsm);
        if((*calculateJacobian)(n_obs, m_vars, x, &tmp_crsm, nfev, &iflag))
        {
            goto freeall;  /* error in splm_intern_fdif_jac */
        }
        splm_ccsm_free(&fjac); // no problem if fjac not already allocated (because splm_ccsm_init_invalid(&fjac) has been executed)
        if (splm_ccsm_alloc(&fjac, n_obs, m_vars, tmp_crsm.nnz))
        {
           goto freeall;
        }
        if (splm_crsm2ccsm(&tmp_crsm, &fjac))
        {
           goto freeall;
        }
        splm_crsm_free(&tmp_crsm);

        if (iflag < 0)
            goto freeall;

        /*
        *	 if requested, call fcn to enable printing of iterates.
        */
        if (nprint > 0)
        {
            iflag = 0;
            if (0 == (iter) % nprint)
            {
                fcn(n_obs, m_vars, x, fvec, &iflag);
                if (iflag < 0)
                    goto freeall;
                // printf( "fnorm %.15e\n", enorm(n_obs,fvec) );
            }
        }

        /*
        *	 compute the qr factorization of the jacobian.
        */
        //print_matrix_s("fjac vor qrfac", &fjac);

        if (perm) { cholmod_l_free(m_vars, sizeof(SuiteSparse_long), perm, &cc); perm = 0; }
        if (R) { splm_ccsm_destruct(R); R = 0; }
        if (qtf) { cholmod_l_free_dense(&qtf, &cc); qtf = 0; }

        dense_wrapper(&cm_fvec, n_obs, 1, fvec);
        const double tol_with_rank_estimation = -2;     /* tol=-2 means rank estimation; necessary for case of rank deficient jacobi but SuiteSparseQR cannot use GPU */
        const double tol_without_rank_estimation = -1;  /* -1: do not estimate rank, so SuiteSparseQR() can use the GPU */
        //printf("start splm_SuiteSparseQR\n");
        rank = splm_SuiteSparseQR(SPQR_ORDERING_BEST, (force_rank_estimation_1 || !cc.useGPU) ? tol_with_rank_estimation : tol_without_rank_estimation,
                                  m_vars, 0, &fjac, 0, &cm_fvec, 0, &qtf, &R, &perm, 0, 0, 0, &cc);
        //printf("finished splm_SuiteSparseQR\n");
        if (rank < 0 || 0 == qtf || 0 == R || 0 == perm)
        {
            goto freeall;   /* error in splm_SuiteSparseQR() */
        }

        //print_matrix_s("R nach qrfac", R);

        for (j = 0; j < rank; j++)
        {
            if (R->colptr[j + 1] <= R->colptr[j] || R->rowidx[R->colptr[j + 1] - 1] != j || zero == R->val[R->colptr[j + 1] - 1])
            {       
                if(force_rank_estimation_1 || !cc.useGPU)
                {
                    goto freeall;   /* splm_SuiteSparseQR() already called with rank estimation, but failed */
                }

                // ssplm_SuiteSparseQR() without rank estimation failed, so try splm_SuiteSparseQR() with rank estimation

                // printf("\nssplm_SuiteSparseQR() without rank estimation failed, so try splm_SuiteSparseQR() with rank estimation\n");

                force_rank_estimation_1 = 1;  /* estimate rank in following iterations */

                if (perm) { cholmod_l_free(m_vars, sizeof(SuiteSparse_long), perm, &cc); perm = 0; }
                if (R) { splm_ccsm_destruct(R); R = 0; }
                if (qtf) { cholmod_l_free_dense(&qtf, &cc); qtf = 0; }

                rank = splm_SuiteSparseQR(SPQR_ORDERING_BEST, tol_with_rank_estimation, m_vars, 0, &fjac, 0, &cm_fvec, 0, &qtf, &R, &perm, 0, 0, 0, &cc);

                if (rank < 0 || 0 == qtf || 0 == R || 0 == perm)
                {
                    goto freeall;   /* error in splm_SuiteSparseQR() */
                }
                for (j = 0; j < rank; j++)
                {
                    if (R->colptr[j + 1] <= R->colptr[j] || R->rowidx[R->colptr[j + 1] - 1] != j || zero == R->val[R->colptr[j + 1] - 1])
                    {
                        goto freeall; // R has zeros within the first 'rank' diagonal elements or R is not upper triangular
                    }
                }
                break;
            }
        }

        /* check the diagonal and compute */
        for (j = 0; j < m_vars; j++)
        {
            if (R->colptr[j + 1] > R->colptr[j] + j + 1)
            {
                goto freeall; // more than j+1 nonzero elements in column j
            }
            for (i = R->colptr[j]; i < R->colptr[j + 1]; i++)
            {
                wa3[i - R->colptr[j]] = R->val[i];
            }
            k = perm[j];
            wa2[k] = enorm(R->colptr[j + 1] - R->colptr[j], wa3);
        }

        /*printf("r_diag = \n");
        for (j = 0; j < m_vars; j++)
        {
            printf("%.16f  ", R->val[R->colptr[j + 1] - 1]);
        }
        printf("\n");*/

        // print_vector_C("wa2 = \n", wa2, m_vars);

        /*
        *	 on the first iteration and if mode is 1, scale according
        *	 to the norms of the columns of the initial jacobian.
        */
        if (0 == iter)
        {
            if (mode != 2)
            {
                for (j = 0; j < m_vars; j++)
                {
                    diag[j] = wa2[j];
                    if (zero == diag[j])
                        diag[j] = one;
                }
            }

            /*
            *	 on the first iteration, calculate the norm of the scaled x
            *	 and initialize the step bound delta.
            */
            for (j = 0; j < m_vars; j++)
                wa3[j] = diag[j] * x[j];

            xnorm = enorm(m_vars, wa3);
            delta = factor * xnorm;
            if (zero == delta)
                delta = factor;
        }

        /*
        *	 compute the norm of the scaled gradient.
        */

        if (0 == (RTqtf = cholmod_l_zeros(m_vars, 1, CHOLMOD_REAL, &cc)))
        {
            goto freeall;
        }

        if (0 == cholmod_l_sdmult(cholmod_sparse_mirror_from_ccsm(R), 1, &complex_one[0], &complex_zero[0], qtf, RTqtf, &cc))
        {
            goto freeall;
        }

        gnorm = zero;
        if (zero != fnorm)
        {
            for (j = 0; j < m_vars; j++)
            {
                k = perm[j];
                if (zero != wa2[k])
                {
                    gnorm = fmax(gnorm, fabs(((double*)RTqtf->x)[j]) / (fnorm * wa2[k]));
                }
            }
        }

        if (0 == cholmod_l_free_dense(&RTqtf, &cc))
        {
            goto freeall;
        }

        // printf("gnorm = %.16f\n", gnorm);

        /*
        *	 test for convergence of the gradient norm.
        */
        if (gnorm <= gtol)
            info = 4;
        if (info != 0)
            goto freeall;
        /*
        *	 rescale if necessary.
        */
        if (mode != 2)
        {
            for (j = 0; j < m_vars; j++)
                diag[j] = fmax(diag[j], wa2[j]);
        }

        /*
        *	 beginning of the inner loop.
        */
        do
        {
            /*
            *	    determine the levenberg-marquardt parameter.
            */
            if (splm_lmpar(m_vars, &fjac, R, perm, diag, &cm_fvec, qtf, delta, &par, wa1, &cc, force_rank_estimation_2))
            {
                goto freeall;
            }

            // printf("par = %.16f\n", par);
            // _vector_C("wa1 = ", wa1, m_vars);
            /*
            *	    store the direction p and x + p. calculate the norm of p.
            */
            for (j = 0; j < m_vars; j++)
            {
                wa1[j] = -wa1[j];
                wa2[j] = x[j] + wa1[j];
                wa3[j] = diag[j] * wa1[j];
            }
            pnorm = enorm(m_vars, wa3);
            // printf("pnorm = %.16f\n", pnorm);

            /*
            *	    on the first iteration, adjust the initial step bound.
            */
            if (0 == iter)
                delta = fmin(delta, pnorm);
            /*
            *	    evaluate the function at x + p and calculate its norm.
            */
            iflag = 1;
            (*fcn)(n_obs, m_vars, wa2, wa4, &iflag);
            *nfev += 1;
            if (iflag < 0)
                goto freeall;
            fnorm1 = enorm(n_obs, wa4);

            /*
            *	    compute the scaled actual reduction.
            */
            actred = -one;
            if ((p1 * fnorm1) < fnorm)
            {
                temp = fnorm1 / fnorm;
                actred = one - temp * temp;
            }
            /*
            *	    compute the scaled predicted reduction and
            *	    the scaled directional derivative.
            */
            for (j = 0; j < m_vars; j++)
            {
                ((double*)Rdxperm->x)[j] = zero;
                k = perm[j];
                wa3[j] = wa1[k];
            }
            dense_wrapper(&dxperm, m_vars, 1, wa3);
            if (0 == cholmod_l_sdmult(cholmod_sparse_mirror_from_ccsm(R), 0, complex_one, complex_zero, &dxperm, Rdxperm, &cc))
            {
                goto freeall;
            }

            temp1 = enorm(m_vars, (double*)Rdxperm->x) / fnorm;
            temp2 = (sqrt(par) * pnorm) / fnorm;
            prered = temp1 * temp1 + (temp2 * temp2) * (one / p5);
            dirder = -(temp1 * temp1 + temp2 * temp2);

            // printf("prered = %.16f\n", prered);
            // printf("dirder = %.16f\n", dirder);

            /*
            *	    compute the ratio of the actual to the predicted
            *	    reduction.
            */
            ratio = zero;
            if (prered != zero)
                ratio = actred / prered;
            /*
            *	    update the step bound.
            */
            if (ratio <= p25)
            {
                if (actred >= zero)
                    temp = p5;
                else
                    temp = p5 * dirder / (dirder + p5 * actred);
                if (((p1 * fnorm1) >= fnorm) || (temp < p1))
                    temp = p1;
                delta = temp * fmin(delta, pnorm * (one / p1));
                par = par / temp;
            }
            else
            {
                if ((zero == par) || (ratio >= p75))
                {
                    delta = pnorm * (one / p5);
                    par = p5 * par;
                }
            }
            /*
            *	    test for successful iteration.
            */
            if (ratio >= p0001)
            {
                /*
                *	    successful iteration. update x, fvec, and their norms.
                */
                for (j = 0; j < m_vars; j++)
                {
                    x[j] = wa2[j];
                    wa2[j] = diag[j] * x[j];
                }
                for (i = 0; i < n_obs; i++)
                    fvec[i] = wa4[i];
                xnorm = enorm(m_vars, wa2);
                fnorm = fnorm1;
            }
            /*
            *	    tests for convergence.
            */
            if ((fabs(actred) <= ftol) && (prered <= ftol) && (p5 * ratio <= one))
                info = 1;
            if (delta <= xtol * xnorm)
                info = 2;
            if ((fabs(actred) <= ftol) && (prered <= ftol) && (p5 * ratio <= one) && (2 == info))
                info = 3;
            if (0 != info)
                goto freeall;
            /*
            *	    tests for termination and stringent tolerances.
            */
            if (*nfev >= maxfev)
                info = 5;
            if ((fabs(actred) <= MACHEP) && (prered <= MACHEP) && (p5 * ratio <= one))
                info = 6;
            if (delta <= MACHEP * xnorm)
                info = 7;
            if (gnorm <= MACHEP)
                info = 8;
            if (0 != info)
                goto freeall;
            /*
            *	    end of the inner loop. repeat if iteration unsuccessful.
            */
        } while (ratio < p0001);
    }

freeall:

    if (iflag < 0)
        info = iflag;
    iflag = 0;
    if (nprint > 0)
        fcn(n_obs, m_vars, x, fvec, &iflag);

    splm_ccsm_free(&fjac);
    splm_crsm_free(&tmp_crsm);  /* no problem if already freed */

    if (R) splm_ccsm_destruct(R);
    if (qtf) cholmod_l_free_dense(&qtf, &cc);
    if (RTqtf) cholmod_l_free_dense(&RTqtf, &cc);
    if (Rdxperm) cholmod_l_free_dense(&Rdxperm, &cc);
    if (perm) cholmod_l_free(m_vars, sizeof(SuiteSparse_long), perm, &cc);

    if (0 == cholmod_l_finish(&cc))
    {
        info = 0;   /* return value 0 is for invalid input parameters, out of memory or internal error */
    }

    if (need_free_fvec && 0!=fvec) free(fvec);
    if (need_free_diag && 0!=diag) free(diag);
    if (wa1) free(wa1);
    if (wa2) free(wa2);
    if (wa3) free(wa3);
    if (wa4) free(wa4);

    return info;
}
