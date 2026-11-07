#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// One process-wide owner. Returns errno (including EBUSY), never allocates.
int cli_signals_acquire(void);
int cli_signals_release(void);
// Termination stays latched until release. Suspension is coalesced.
int cli_signals_termination(void);
int cli_signals_take_suspend(void);
int cli_signals_suspend(void);

#ifdef __cplusplus
}
#endif
