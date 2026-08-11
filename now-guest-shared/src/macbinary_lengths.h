#ifndef NOW_MACBINARY_LENGTHS_H
#define NOW_MACBINARY_LENGTHS_H

/* Decode MacBinary's two unsigned 32-bit fork lengths into the signed-long
 * File Manager model shared by both guests. The complete padded envelope
 * must fit in envelope_length; malformed lengths are rejected before either
 * guest uses them to route bytes to a fork. */
int now_macbinary_fork_lengths(const unsigned char header[128],
                               long envelope_length,
                               long *data_length,
                               long *resource_length);

#endif
