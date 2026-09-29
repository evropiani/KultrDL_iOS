#ifndef KDL_BCRYPT_PBKDF_H
#define KDL_BCRYPT_PBKDF_H

#include <stddef.h>
#include <stdint.h>

/**
 * OpenBSD's bcrypt_pbkdf: derives `keylen` bytes of key from a passphrase
 * and salt with the given number of rounds. Returns 0, or -1 when the
 * arguments are out of range.
 */
int kdl_bcrypt_pbkdf(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                     uint8_t *key, size_t keylen, unsigned int rounds);

#endif
