#ifndef OPUS_BRIDGE_H
#define OPUS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct SimOpusEnc SimOpusEnc;
typedef struct SimOpusDec SimOpusDec;

SimOpusEnc * _Nullable sim_opus_encoder_create(int32_t sample_rate, int32_t channels, int32_t bitrate_bps, int32_t complexity);
int32_t sim_opus_encode(SimOpusEnc * _Nullable enc, const int16_t * _Nonnull pcm, int32_t frame_size, uint8_t * _Nonnull out_data, int32_t max_out_bytes);
void sim_opus_encoder_destroy(SimOpusEnc * _Nullable enc);

SimOpusDec * _Nullable sim_opus_decoder_create(int32_t sample_rate, int32_t channels);
int32_t sim_opus_decode(SimOpusDec * _Nullable dec, const uint8_t * _Nullable data, int32_t len, int16_t * _Nonnull pcm_out, int32_t frame_size, int32_t decode_fec);
void sim_opus_decoder_destroy(SimOpusDec * _Nullable dec);

#endif
