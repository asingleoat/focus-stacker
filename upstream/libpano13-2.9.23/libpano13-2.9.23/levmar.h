///////////////////////////////////////////////////////////////////////////////
//
//  Header file for the Sparse levenberg marquardt algorithm
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

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <memory.h>
#include <inttypes.h>

#include <cholmod.h>
#include <SuiteSparseQR_C.h>

typedef struct
{
    SuiteSparse_long nr, nc;   /* #rows, #cols for the sparse matrix */
    SuiteSparse_long nnz;      /* number of nonzero array elements */
    double* val;  /* storage for nonzero array elements. size: nnz */
    SuiteSparse_long* colidx;  /* column indexes of nonzero elements. size: nnz */
    SuiteSparse_long* rowptr;  /* locations in val that start a row. size: nr+1.
                   * By convention, rowptr[nr]=nnz
                   */
} splm_crsm;

/* Sparse matrix representation using Compressed Column Storage (CCS) format.
 * See http://www.netlib.org/linalg/html_templates/node92.html
 */

typedef struct
{
    SuiteSparse_long nr, nc;   /* #rows, #cols for the sparse matrix */
    SuiteSparse_long nnz;      /* number of nonzero array elements */
    double* val;  /* storage for nonzero array elements. size: nnz */
    SuiteSparse_long* rowidx;  /* row indexes of nonzero elements. size: nnz */
    SuiteSparse_long* colptr;  /* locations in val that start a column. size: nc+1.
                   * By convention, colptr[nc]=nnz
                   */
    cholmod_sparse static_cm_mirror;
    cholmod_sparse* cm_owner;
    cholmod_common* cm_common;
} splm_ccsm;

SuiteSparse_long splm_crsm2ccsm(splm_crsm* crs, splm_ccsm* ccs);
void splm_ccsm_init_invalid(splm_ccsm* sm);
SuiteSparse_long splm_ccsm_alloc(splm_ccsm* sm, SuiteSparse_long nr, SuiteSparse_long nc, SuiteSparse_long nnz);
void splm_ccsm_free(splm_ccsm* sm);
SuiteSparse_long splm_ccsm_elmidx(splm_ccsm* sm, SuiteSparse_long i, SuiteSparse_long j);
SuiteSparse_long splm_ccsm_col_maxnelms(splm_ccsm* sm);
SuiteSparse_long splm_ccsm_col_elmidxs(splm_ccsm* sm, SuiteSparse_long j, SuiteSparse_long* vidxs, SuiteSparse_long* iidxs);

void splm_crsm_init_invalid(splm_crsm* sm);
SuiteSparse_long splm_crsm_alloc_novalues(splm_crsm* sm, SuiteSparse_long nr, SuiteSparse_long nc, SuiteSparse_long nnz);
SuiteSparse_long splm_crsm_alloc_rest(splm_crsm* sm, SuiteSparse_long nnz);
void splm_crsm_free(splm_crsm* sm);
splm_ccsm* cholmod_sparse_to_splm_ccsm(cholmod_sparse* cmsp, cholmod_common* cm_common);
void splm_ccsm_destruct(splm_ccsm* sm);
cholmod_sparse* cholmod_sparse_mirror_from_ccsm(splm_ccsm* sm);

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
);

cholmod_dense* dense_wrapper(cholmod_dense* X, SuiteSparse_long nrow, SuiteSparse_long ncol, double* Xx);

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
);

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
);

int lmdif_sparse(int n_obs, int m_vars,
    int(*fcn)(int n_obs, int m_vars, double* x, double* fvec, int* iflag),
    int (*calculateJacobian)(int n_obs, int m_vars, double* x, splm_crsm* jac, int* nfeval, int* iflag),
    double* x, double* fvec,
    double ftol, double xtol, double gtol,
    int maxfev, double epsfcn, double mindeltax, int forward_diff,
    double *diag,
    int mode, double factor,
    int force_rank_estimation_1,
    int force_rank_estimation_2,
    int nprint, int* nfev
);
