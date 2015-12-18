/*
 * Copyright (c) 2009, Google Inc.
 * All rights reserved.
 *
 * Copyright (c) 2009-2015, The Linux Foundation. All rights reserved.
 * Copyright (c) 2015, Linaro Limited. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of The Linux Foundation nor
 *       the names of its contributors may be used to endorse or promote
 *       products derived from this software without specific prior written
 *       permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NON-INFRINGEMENT ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include "sparse_format.h"
#include <limits.h>
#include <malloc.h>

#if defined(DEBUG)
#define DEBUGLEVEL DEBUG
#else
#define DEBUGLEVEL 2
#endif

/* debug levels */
#define CRITICAL 0
#define ALWAYS 0
#define INFO 1
#define SPEW 2

#define dprintf(level, x...) do { if ((level) <= DEBUGLEVEL) { printf(x); } } while (0)

//FIXME
#define CACHE_LINE 64
#define fastboot_fail printf
#define fastboot_okay printf
#define ROUNDUP(a, b) (((a) + ((b)-1)) & ~((b)-1))

uint32_t mmc_write(uint64_t offset, uint32_t len, void* data, FILE* out)
{
	int written;
	dprintf (SPEW, "=== mmc write ===\n");
	dprintf (SPEW, "offset: %ld\n", offset);
	dprintf (SPEW, "len: %d\n", len);
    
	if (fseek(out, offset, SEEK_SET)) {
		dprintf (CRITICAL, "mmc_write fails: %d written instead of %d\n");
		return -1;
	}

	written = fwrite(data, 1, len, out);
	if ( written != len ) {
		dprintf (CRITICAL, "mmc_write fails: %d written instead of %d\n",
			written, len);
		return -1;
	}

	return 0;
}

void flash_mmc_sparse_img(FILE* fp, FILE* out, uint64_t size)
{
	unsigned int chunk;
	unsigned int chunk_data_sz;
	uint32_t *fill_buf = NULL;
	uint32_t fill_val;
	uint32_t chunk_blk_cnt = 0;
	sparse_header_t *sparse_header;
	chunk_header_t *chunk_header;
	uint32_t total_blocks = 0;
	int i;
	void *data = 0;

	sparse_header = (sparse_header_t*) malloc(sizeof(sparse_header_t));
	chunk_header = (chunk_header_t*) malloc(sizeof(chunk_header_t));

	/* Read and skip over sparse image header */
	fread(sparse_header, sizeof(sparse_header_t), 1, fp);

	if (((uint64_t)sparse_header->total_blks * (uint64_t)sparse_header->blk_sz) > size) {
		fastboot_fail("size too large");
		return;
	}

	if(sparse_header->file_hdr_sz > sizeof(sparse_header_t))
	{
		/* Skip the remaining bytes in a header that is longer than
		 * we expected.
		 */
		fseek(fp, sparse_header->file_hdr_sz - sizeof(sparse_header_t), SEEK_CUR);
	}

	dprintf (ALWAYS, "=== Sparse Image Header ===\n");
	dprintf (ALWAYS, "magic: 0x%x\n", sparse_header->magic);
	dprintf (ALWAYS, "major_version: 0x%x\n", sparse_header->major_version);
	dprintf (ALWAYS, "minor_version: 0x%x\n", sparse_header->minor_version);
	dprintf (ALWAYS, "file_hdr_sz: %d\n", sparse_header->file_hdr_sz);
	dprintf (ALWAYS, "chunk_hdr_sz: %d\n", sparse_header->chunk_hdr_sz);
	dprintf (ALWAYS, "blk_sz: %d\n", sparse_header->blk_sz);
	dprintf (ALWAYS, "total_blks: %d\n", sparse_header->total_blks);
	dprintf (ALWAYS, "total_chunks: %d\n", sparse_header->total_chunks);

	/* Start processing chunks */
	for (chunk=0; chunk<sparse_header->total_chunks; chunk++)
	{
		/* Make sure the total image size does not exceed the partition size */
		if(((uint64_t)total_blocks * (uint64_t)sparse_header->blk_sz) >= size) {
			fastboot_fail("size too large");
			return;
		}
		/* Read and skip over chunk header */
		fread(chunk_header, sizeof(chunk_header_t), 1, fp);

		dprintf (SPEW, "=== Chunk Header ===\n");
		dprintf (SPEW, "chunk_id: %d\n", chunk);
		dprintf (SPEW, "chunk_type: 0x%x\n", chunk_header->chunk_type);
		dprintf (SPEW, "chunk_data_sz: %d\n", chunk_header->chunk_sz);
		dprintf (SPEW, "total_size: %d\n", chunk_header->total_sz);

		if(sparse_header->chunk_hdr_sz > sizeof(chunk_header_t))
		{
			/* Skip the remaining bytes in a header that is longer than
			 * we expected.
			 */
			fseek(fp, sparse_header->chunk_hdr_sz - sizeof(chunk_header_t), SEEK_CUR);
		}

		chunk_data_sz = sparse_header->blk_sz * chunk_header->chunk_sz;

		switch (chunk_header->chunk_type)
		{
		case CHUNK_TYPE_RAW:
			/* Make sure multiplication does not overflow uint32 size */
			if (sparse_header->blk_sz && (chunk_header->chunk_sz != chunk_data_sz / sparse_header->blk_sz))
			{
				fastboot_fail("Bogus size sparse and chunk header");
				return;
			}

			/* Make sure that the chunk size calculated from sparse image does not
			 * exceed partition size
			 */
			if ((uint64_t)total_blocks * (uint64_t)sparse_header->blk_sz + chunk_data_sz > size)
			{
				fastboot_fail("Chunk data size exceeds partition size");
				return;
			}

			if(chunk_header->total_sz != (sparse_header->chunk_hdr_sz +
							chunk_data_sz))
			{
				fastboot_fail("Bogus chunk size for chunk type Raw");
				return;
			}

			data = malloc(chunk_data_sz);
			fread(data, 1, chunk_data_sz, fp);
			if(mmc_write(((uint64_t)total_blocks*sparse_header->blk_sz),
					chunk_data_sz,
					data,
					out))
			{
				fastboot_fail("flash write failure");
				free(data);
				return;
			}

			free(data);
			if(total_blocks > (UINT_MAX - chunk_header->chunk_sz)) {
				fastboot_fail("Bogus size for RAW chunk type");
				return;
			}
			total_blocks += chunk_header->chunk_sz;
			break;

		case CHUNK_TYPE_FILL:
			if(chunk_header->total_sz != (sparse_header->chunk_hdr_sz +
							sizeof(uint32_t)))
			{
				fastboot_fail("Bogus chunk size for chunk type FILL");
				return;
			}

			fill_buf = (uint32_t *)malloc(sparse_header->blk_sz);
			if (!fill_buf)
			{
				fastboot_fail("Malloc failed for: CHUNK_TYPE_FILL");
				return;
			}

			fread(&fill_val, sizeof(uint32_t), 1, fp);
			chunk_blk_cnt = chunk_data_sz / sparse_header->blk_sz;

			for (i = 0; i < sparse_header->blk_sz / sizeof(fill_val); i++)
			{
				fill_buf[i] = fill_val;
			}

			for (i = 0; i < chunk_blk_cnt; i++)
			{
				/* Make sure that the data written to partition does not exceed partition size */
				if ((uint64_t)total_blocks * (uint64_t)sparse_header->blk_sz + sparse_header->blk_sz > size)
				{
					fastboot_fail("Chunk data size for fill type exceeds partition size");
					return;
				}

				if(mmc_write(((uint64_t)total_blocks*sparse_header->blk_sz),
						sparse_header->blk_sz,
						fill_buf,
						out))
				{
					fastboot_fail("flash write failure");
					free(fill_buf);
					return;
				}

				total_blocks++;
			}

			free(fill_buf);
			break;

		case CHUNK_TYPE_DONT_CARE:
			if(total_blocks > (UINT_MAX - chunk_header->chunk_sz)) {
				fastboot_fail("bogus size for chunk DONT CARE type");
				return;
			}

			total_blocks += chunk_header->chunk_sz;
			break;

		case CHUNK_TYPE_CRC:
			if(chunk_header->total_sz != sparse_header->chunk_hdr_sz)
			{
				fastboot_fail("Bogus chunk size for chunk type Dont Care");
				return;
			}
			if(total_blocks > (UINT_MAX - chunk_header->chunk_sz)) {
				fastboot_fail("bogus size for chunk CRC type");
				return;
			}
			total_blocks += chunk_header->chunk_sz;
			fseek(fp, chunk_data_sz, SEEK_CUR);
			break;

		default:
			dprintf(CRITICAL, "Unkown chunk type: %x\n",chunk_header->chunk_type);
			fastboot_fail("Unknown chunk type");
			return;
		}
	}

	/* if last chunk was DONT_CARE, we need to write something to
	 * set the stream size properly * otherwise we might have seek
	 * beyong end of file, and that will be discarded on close
	 */
	if (chunk_header->chunk_type == CHUNK_TYPE_DONT_CARE) {
		fseek(out, total_blocks*sparse_header->blk_sz - 1, SEEK_SET);
		fill_val = 0;
		fwrite(&fill_val, 1, 1, out);
	}

	dprintf(INFO, "Wrote %d blocks, expected to write %d blocks\n",
		total_blocks, sparse_header->total_blks);
    
	if(total_blocks != sparse_header->total_blks)
	{
		fastboot_fail("sparse image write failure");
	}

	fastboot_okay("DONE, OKAY\n");
	return;
}

void main(int argc, char *argv[]) {
	FILE *f_in, *f_out;
	f_in = fopen(argv[1], "rb");
	f_out = fopen(argv[2], "wb+");
	flash_mmc_sparse_img(f_in, f_out, (uint64_t)2*1024*1024*1024);
	fclose(f_in);
	fclose(f_out);
}
