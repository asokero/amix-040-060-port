/* b2verify.c - B2 copyback corruption classifier (Part A of
 * amix-kernel-analysis vm-map/B2-CORRUPTION-FIX-SPEC.md).
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * PURPOSE: SVR4 `sum` hides errno and prints a PARTIAL read-progress count
 * after ferror(), so "32757 5328 + read error" does NOT prove a short inode or
 * persistent disk corruption -- it only proves the reader stopped at ~5328
 * blocks.  This tool reads the destination with UNBUFFERED open/read, captures
 * the real errno + fstat st_size + a reopen/retry result, and prints a machine-
 * greppable classification (V0..V6) so a transient ISSUE-22 EFAULT can never be
 * confused with genuine disk truth.
 *
 * Usage:  b2verify <source> <destination> [label]
 *   source      = the reference file (e.g. the NFS payload) -- read-only ground truth
 *   destination = the freshly copied local file to classify -- NEVER modified
 *   label       = optional run/kernel tag echoed into the record
 *
 * Exit status = the numeric V-class (0 = COMPLETE_MATCH) so a shell driver can
 * branch on it; 20 = usage/source error (distinct from any V-class).
 *
 * Compile on AMIX:  cc -o b2verify b2verify.c
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define CHUNK	8192

/* V-classes (also the process exit status) */
#define V0_COMPLETE_MATCH	0
#define V1_EFAULT_TRANSIENT	1
#define V2_EFAULT_PERSISTENT	2
#define V3_EIO_PERSISTENT	3
#define V4_INODE_SHORT		4
#define V5_DATA_MISMATCH	5
#define V6_METADATA_INCONSISTENT 6
#define VX_SOURCE_ERROR		20

char *srcbuf;			/* whole source file, ground truth */
char dstbuf[CHUNK];
long srcsize;

/* historic SVR4 `sum` (algorithm 0) checksum, so the output line stays directly
 * comparable to the sum numbers already captured in the control runs. */
sum16(buf, n, crcp)
char *buf;
long n;
unsigned *crcp;
{
	unsigned crc;
	long i;

	crc = *crcp;
	for (i = 0; i < n; i++) {
		crc = (crc >> 1) + ((crc & 1) << 15) + (buf[i] & 0xff);
		crc = crc & 0xffff;
	}
	*crcp = crc;
}

/* read the whole source into srcbuf; returns 0 ok, -1 fail */
loadsource(path)
char *path;
{
	int fd;
	long off;
	int r;
	struct stat st;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return (-1);
	if (fstat(fd, &st) < 0) {
		close(fd);
		return (-1);
	}
	srcsize = st.st_size;
	srcbuf = (char *)malloc((unsigned)srcsize);
	if (srcbuf == (char *)0) {
		close(fd);
		return (-1);
	}
	off = 0;
	while (off < srcsize) {
		r = read(fd, srcbuf + off, (unsigned)CHUNK);
		if (r <= 0) {
			close(fd);
			return (-1);
		}
		off = off + r;
	}
	close(fd);
	return (0);
}

/* retry the failing offset up to 3x after close/reopen; returns 1 if any retry
 * succeeded (transient), 0 if it kept failing (persistent).  Sets *rerrno to the
 * errno of the last failed retry. */
retry_offset(path, foff, rerrno)
char *path;
long foff;
int *rerrno;
{
	int fd;
	int t;
	int r;

	for (t = 0; t < 3; t++) {
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			*rerrno = errno;
			continue;
		}
		if (lseek(fd, foff, 0) < 0) {
			*rerrno = errno;
			close(fd);
			continue;
		}
		errno = 0;
		r = read(fd, dstbuf, (unsigned)CHUNK);
		if (r > 0) {
			close(fd);
			return (1);
		}
		*rerrno = errno;
		close(fd);
	}
	return (0);
}

main(argc, argv)
int argc;
char **argv;
{
	char *src;
	char *dst;
	char *label;
	int fd;
	long off;
	int r;
	int i;
	int reado;		/* saved errno at first read failure */
	int rerrno;
	int transient;
	struct stat st0;
	struct stat st1;
	unsigned dcrc;
	long mismatch;

	if (argc < 3) {
		fprintf(stderr, "usage: b2verify <source> <destination> [label]\n");
		exit(VX_SOURCE_ERROR);
	}
	src = argv[1];
	dst = argv[2];
	label = (argc > 3) ? argv[3] : "-";

	if (loadsource(src) < 0) {
		printf("B2V label=%s CLASS=SOURCE_ERROR src=%s errno=%d\n",
		    label, src, errno);
		exit(VX_SOURCE_ERROR);
	}

	/* metadata snapshot of the destination BEFORE reading */
	if (stat(dst, &st0) < 0) {
		printf("B2V label=%s CLASS=SOURCE_ERROR dst=%s stat_errno=%d\n",
		    label, dst, errno);
		exit(VX_SOURCE_ERROR);
	}
	printf("B2V label=%s path=%s dev=%ld ino=%lu mode=%o nlink=%d size=%ld srcsize=%ld mtime=%ld ctime=%ld\n",
	    label, dst, (long)st0.st_dev, (unsigned long)st0.st_ino,
	    (int)st0.st_mode, (int)st0.st_nlink, (long)st0.st_size, srcsize,
	    (long)st0.st_mtime, (long)st0.st_ctime);

	fd = open(dst, O_RDONLY);
	if (fd < 0) {
		printf("B2V label=%s CLASS=OPEN_FAIL dst=%s errno=%d\n",
		    label, dst, errno);
		exit(VX_SOURCE_ERROR);
	}

	off = 0;
	dcrc = 0;
	mismatch = -1;
	for (;;) {
		errno = 0;
		r = read(fd, dstbuf, (unsigned)CHUNK);
		if (r == 0)
			break;			/* EOF */
		if (r < 0) {
			/* READ FAILURE -- the whole point: capture errno + retry */
			reado = errno;
			fstat(fd, &st1);
			close(fd);
			rerrno = reado;
			transient = retry_offset(dst, off, &rerrno);
			printf("B2V label=%s READFAIL off=%ld errno=%d size_at_fail=%ld retry_transient=%d retry_errno=%d bytes_ok=%ld\n",
			    label, off, reado, (long)st1.st_size, transient,
			    rerrno, off);
			if (transient) {
				printf("B2V label=%s CLASS=%s off=%ld errno=%d note=reopen-succeeded-file-intact\n",
				    label,
				    (reado == EFAULT) ? "V1_EFAULT_TRANSIENT"
				                      : "V1_TRANSIENT",
				    off, reado);
				exit(V1_EFAULT_TRANSIENT);
			}
			if (reado == EFAULT) {
				printf("B2V label=%s CLASS=V2_EFAULT_PERSISTENT off=%ld\n",
				    label, off);
				exit(V2_EFAULT_PERSISTENT);
			}
			printf("B2V label=%s CLASS=V3_EIO_PERSISTENT off=%ld errno=%d\n",
			    label, off, reado);
			exit(V3_EIO_PERSISTENT);
		}
		/* got r bytes -- checksum and byte-compare against source */
		sum16(dstbuf, (long)r, &dcrc);
		if (mismatch < 0) {
			for (i = 0; i < r; i++) {
				if (off + i >= srcsize ||
				    dstbuf[i] != srcbuf[off + i]) {
					mismatch = off + i;
					break;
				}
			}
		}
		off = off + r;
	}
	close(fd);

	printf("B2V label=%s read_total=%ld dst_crc=%u dst_blocks=%ld\n",
	    label, off, dcrc, (off + 511) / 512);

	if (st0.st_size < srcsize) {
		printf("B2V label=%s CLASS=V4_INODE_SHORT size=%ld srcsize=%ld\n",
		    label, (long)st0.st_size, srcsize);
		exit(V4_INODE_SHORT);
	}
	if (mismatch >= 0) {
		printf("B2V label=%s CLASS=V5_DATA_MISMATCH first_diff=%ld read_total=%ld\n",
		    label, mismatch, off);
		exit(V5_DATA_MISMATCH);
	}
	if (off != srcsize) {
		/* fully read without a read error but length != source and no
		 * short st_size: block-map / metadata inconsistency candidate */
		printf("B2V label=%s CLASS=V6_METADATA_INCONSISTENT read_total=%ld srcsize=%ld size=%ld\n",
		    label, off, srcsize, (long)st0.st_size);
		exit(V6_METADATA_INCONSISTENT);
	}
	printf("B2V label=%s CLASS=V0_COMPLETE_MATCH size=%ld crc=%u\n",
	    label, (long)st0.st_size, dcrc);
	exit(V0_COMPLETE_MATCH);
}
