#include "OpusBridge.h"
#include "opus.h"
#include <stdlib.h>

struct SimOpusEnc {
    OpusEncoder *enc;
};

struct SimOpusDec {
    OpusDecoder *dec;
};

SimOpusEnc *sim_opus_encoder_create(int32_t sample_rate, int32_t channels, int32_t bitrate_bps, int32_t complexity) {
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(sample_rate, channels, OPUS_APPLICATION_VOIP, &err);
    if (err != OPUS_OK || !enc) {
        return NULL;
    }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate_bps));
    opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(5));
    opus_encoder_ctl(enc, OPUS_SET_DTX(0));

    SimOpusEnc *wrap = (SimOpusEnc *)malloc(sizeof(SimOpusEnc));
    if (!wrap) {
        opus_encoder_destroy(enc);
        return NULL;
    }
    wrap->enc = enc;
    return wrap;
}

int32_t sim_opus_encode(SimOpusEnc *enc, const int16_t *pcm, int32_t frame_size, uint8_t *out_data, int32_t max_out_bytes) {
    if (!enc || !enc->enc) return -1;
    return opus_encode(enc->enc, pcm, frame_size, out_data, max_out_bytes);
}

void sim_opus_encoder_destroy(SimOpusEnc *enc) {
    if (!enc) return;
    if (enc->enc) opus_encoder_destroy(enc->enc);
    free(enc);
}

SimOpusDec *sim_opus_decoder_create(int32_t sample_rate, int32_t channels) {
    int err = OPUS_OK;
    OpusDecoder *dec = opus_decoder_create(sample_rate, channels, &err);
    if (err != OPUS_OK || !dec) {
        return NULL;
    }
    SimOpusDec *wrap = (SimOpusDec *)malloc(sizeof(SimOpusDec));
    if (!wrap) {
        opus_decoder_destroy(dec);
        return NULL;
    }
    wrap->dec = dec;
    return wrap;
}

int32_t sim_opus_decode(SimOpusDec *dec, const uint8_t *data, int32_t len, int16_t *pcm_out, int32_t frame_size, int32_t decode_fec) {
    if (!dec || !dec->dec) return -1;
    return opus_decode(dec->dec, data, len, pcm_out, frame_size, decode_fec ? 1 : 0);
}

void sim_opus_decoder_destroy(SimOpusDec *dec) {
    if (!dec) return;
    if (dec->dec) opus_decoder_destroy(dec->dec);
    free(dec);
}
