/** A fiber interface based on "reified fibers". **/
#ifndef WASMFX_REIFIBER_C_H
#define WASMFX_REIFIBER_C_H

#define export(NAME) __attribute__((export_name(NAME)))

/* An abstract type for the "self" reference that is passed to a fiber and which
is needed to be able to suspend. */
typedef void *reifiber_ref_t;

/** The signature of a fiber entry point. **/
typedef void* (*reifiber_entry_point_t)(reifiber_ref_t, void*);

/** The C-level abstract type that we use to track the things. **/
typedef struct reifiber* reifiber_t;

/** Allocates a new fiber with the default stack size. **/
export("fiber_alloc")
reifiber_t reifiber_alloc(reifiber_entry_point_t entry);

/** Reclaims the memory occupied by the reifiber object. **/
export("fiber_free")
void reifiber_free(reifiber_t reifiber);

/** Yields control to its parent context. This function must be called
    from within a reifiber context.
    "self" in a way identifies the parent, the fiber that called resume
     **/
export("reifiber_yield")
void* reifiber_yield(reifiber_ref_t self, void *arg);

/** Possible status codes for `reifiber_resume`. **/
typedef enum { FIBER_OK = 0, FIBER_YIELD = 1, FIBER_ERROR = 2 } fiber_result_t;

/** Resumes a given `reifiber` with argument `arg`, returning some value
    of type `void*`. The output parameter `status` indicates whether
    the fiber ran to completion (`FIBER_OK`), yielded control
    (`FIBER_YIELD`), or failed (`FIBER_ERROR`), in the latter case the
    return value will always be `NULL`. **/
export("reifiber_resume")
void* reifiber_resume(reifiber_t reifiber, void *arg, fiber_result_t *status);


/** Initialises the reifiber runtime. It must be called exactly once
    before using any of the other reifiber_* functions. **/
export("reifiber_init")
void reifiber_init(void);

/** Tears down the reifiber runtime. It must be called after the final
    use of any of the other reifiber_* functions. **/
export("reifiber_finalize")
void reifiber_finalize(void);

#undef export
#endif
