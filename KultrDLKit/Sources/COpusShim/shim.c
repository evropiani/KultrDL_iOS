#include "COpusShim.h"
#include <opus/opusenc.h>

int kdl_ope_set_bitrate(void *enc, int32_t bitrate) {
    return ope_encoder_ctl((OggOpusEnc *)enc, OPUS_SET_BITRATE(bitrate));
}

int kdl_ope_set_vbr(void *enc, int32_t vbr) {
    return ope_encoder_ctl((OggOpusEnc *)enc, OPUS_SET_VBR(vbr));
}

int kdl_ope_set_complexity(void *enc, int32_t complexity) {
    return ope_encoder_ctl((OggOpusEnc *)enc, OPUS_SET_COMPLEXITY(complexity));
}

int kdl_ope_set_music(void *enc) {
    return ope_encoder_ctl((OggOpusEnc *)enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
}
