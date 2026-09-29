#ifndef COPUSSHIM_H
#define COPUSSHIM_H

#include <stdint.h>

// libopusenc's settings are set through a variadic function, which Swift
// can't call; these wrap the ones KultrDL needs. [enc] is an OggOpusEnc *.

/** OPUS_SET_BITRATE; returns the libopusenc error code (0 is OK). */
int kdl_ope_set_bitrate(void *enc, int32_t bitrate);

/** OPUS_SET_VBR (1 on, 0 off). */
int kdl_ope_set_vbr(void *enc, int32_t vbr);

/** OPUS_SET_COMPLEXITY (0…10). */
int kdl_ope_set_complexity(void *enc, int32_t complexity);

/** OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC). */
int kdl_ope_set_music(void *enc);

#endif
