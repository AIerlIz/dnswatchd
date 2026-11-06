// SPDX-License-Identifier: MIT
//
// dnswatch-probe - single-shot DNS A-record probe with response validation
//
// Emits exactly one JSON object on stdout, always. Exit status:
//   0  healthy  (class == "")
//   1  unhealthy
//   2  usage / internal error
//
// Why this exists instead of busybox `nslookup`:
//   * busybox `nslookup -timeout=1` does not bound the wall clock (~5s observed
//     on a blackholed server), so a dead upstream can eat a whole round.
//   * Its output is text, and every consumer ends up taking the *last* Address
//     line, silently dropping the other A records. We need all of them.
//   * We want the real DNS round-trip time, not an ICMP ping proxy.
//
// The probe never uses the libc resolver: it speaks UDP (and TCP on truncation)
// directly, so a static musl build has no NSS dependency at all.
//
// Classes (uniform threshold treatment, distinct only for observability):
//   timeout       no reply within the deadline, or a transport failure
//   no-answer     a reply arrived but carried no usable A record
//                 (NXDOMAIN / SERVFAIL / REFUSED / NODATA)
//   wrong-answer  A records exist but violate the expectation
// The `rcode` and `error` fields carry the detail.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MAX_ADDRS       16
#define QNAME_MAX       254
#define QUERY_MAX       512
#define RESPONSE_MAX    4096
#define DEF_DEADLINE_MS 2000
#define MIN_DEADLINE_MS 100
#define MAX_DEADLINE_MS 60000

enum expect_mode { MODE_IN, MODE_NOT_IN, MODE_ANY };

struct result {
	int ok;
	const char *cls;        /* "" | timeout | no-answer | wrong-answer */
	const char *rcode;      /* NOERROR / NXDOMAIN / ... / ""              */
	const char *error;      /* transport detail, never a format string    */
	double rtt_ms;          /* -1 when no reply was seen                  */
	int naddr;
	char addr[MAX_ADDRS][INET_ADDRSTRLEN];
};

static double
now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* ---------------------------------------------------------------- usage */

static void
usage(void)
{
	fprintf(stderr,
		"usage: dnswatch-probe -s ADDR [-p PORT] -d DOMAIN [-m in|not-in|any]\n"
		"                      [-c CIDR] [-t DEADLINE_MS]\n");
}

/* ---------------------------------------------------------------- validate */

static int
valid_domain(const char *d)
{
	size_t len, label = 0, total = 0;
	const char *p;

	if (!d || !*d)
		return 0;
	len = strlen(d);
	if (len > QNAME_MAX)
		return 0;

	for (p = d; ; p++) {
		if (*p == '.' || *p == '\0') {
			if (label == 0 || label > 63)
				return 0;
			if (label == 1 && p[-1] == '-')
				return 0;
			total++;
			label = 0;
			if (*p == '\0')
				break;
			continue;
		}
		if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
		      (*p >= '0' && *p <= '9') || *p == '-' || *p == '_'))
			return 0;
		label++;
	}

	return total >= 1;
}

/* a.b.c.d/n -> (network, prefix). Both must be plain dotted quads. */
static int
parse_cidr(const char *s, struct in_addr *net, int *prefix)
{
	char buf[64], *slash, *end;
	long p;

	if (strlen(s) >= sizeof(buf))
		return -1;
	strcpy(buf, s);

	slash = strchr(buf, '/');
	if (!slash)
		return -1;
	*slash = '\0';

	if (inet_pton(AF_INET, buf, net) != 1)
		return -1;

	errno = 0;
	p = strtol(slash + 1, &end, 10);
	if (errno || *end != '\0' || p < 0 || p > 32)
		return -1;

	*prefix = (int)p;
	return 0;
}

static int
cidr_match(const struct in_addr *ip, const struct in_addr *net, int prefix)
{
	uint32_t mask;

	if (prefix == 0)
		return 1;

	mask = htonl(prefix == 32 ? 0xFFFFFFFFu : ~((1u << (32 - prefix)) - 1));

	return (ip->s_addr & mask) == (net->s_addr & mask);
}

/* ---------------------------------------------------------------- wire */

static uint16_t
random_id(void)
{
	uint16_t id = 0;
	int fd = open("/dev/urandom", O_RDONLY);

	if (fd >= 0) {
		if (read(fd, &id, sizeof(id)) != (ssize_t)sizeof(id))
			id = 0;
		close(fd);
	}
	if (id == 0)
		id = (uint16_t)((now_ms() * 1000) + getpid());

	return id;
}

static int
build_query(unsigned char *buf, size_t bufsz, const char *domain, uint16_t id)
{
	size_t pos = 12;
	const char *p = domain, *dot;

	if (bufsz < 12)
		return -1;

	memset(buf, 0, 12);
	buf[0] = (unsigned char)(id >> 8);
	buf[1] = (unsigned char)(id & 0xFF);
	buf[2] = 0x01;      /* RD */
	buf[3] = 0x00;
	buf[4] = 0x00; buf[5] = 0x01;   /* qdcount = 1 */

	while (*p) {
		size_t l;

		dot = strchr(p, '.');
		l = dot ? (size_t)(dot - p) : strlen(p);
		if (l == 0 || l > 63 || pos + 1 + l + 5 > bufsz)
			return -1;
		buf[pos++] = (unsigned char)l;
		memcpy(buf + pos, p, l);
		pos += l;
		p += l;
		if (*p == '.')
			p++;
	}
	buf[pos++] = 0x00;
	buf[pos++] = 0x00; buf[pos++] = 0x01;  /* QTYPE  A   */
	buf[pos++] = 0x00; buf[pos++] = 0x01;  /* QCLASS IN  */

	return (int)pos;
}

static int
wait_fd(int fd, short events, int timeout_ms)
{
	struct pollfd pfd;
	int rv;

	pfd.fd = fd;
	pfd.events = events;
	pfd.revents = 0;

	do {
		rv = poll(&pfd, 1, timeout_ms);
	} while (rv < 0 && errno == EINTR);

	if (rv <= 0)
		return -1;

	return (pfd.revents & events) ? 0 : -1;
}

static int
udp_exchange(const struct sockaddr_in *srv, const unsigned char *q, int qlen,
             unsigned char *r, int *rlen, int deadline_ms, uint16_t id,
             struct result *res)
{
	int fd, len;
	double t0, t1;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		res->error = "socket() failed";
		return -1;
	}

	if (connect(fd, (const struct sockaddr *)srv, sizeof(*srv)) < 0) {
		res->error = "connect() failed";
		close(fd);
		return -1;
	}

	t0 = now_ms();

	if (send(fd, q, (size_t)qlen, 0) != qlen) {
		res->error = "send() failed";
		close(fd);
		return -1;
	}

	for (;;) {
		int left = deadline_ms - (int)(now_ms() - t0);

		if (left <= 0) {
			res->error = "no reply before deadline";
			close(fd);
			return -1;
		}
		if (wait_fd(fd, POLLIN, left) < 0) {
			res->error = "no reply before deadline";
			close(fd);
			return -1;
		}

		len = (int)recv(fd, r, RESPONSE_MAX, 0);
		if (len < 12) {
			res->error = "short reply";
			close(fd);
			return -1;
		}
		/* Ignore stray datagrams that do not belong to this query. */
		if (((r[0] << 8) | r[1]) != id)
			continue;
		break;
	}

	t1 = now_ms();
	res->rtt_ms = t1 - t0;
	*rlen = len;
	close(fd);

	return 0;
}

static int
tcp_exchange(const struct sockaddr_in *srv, const unsigned char *q, int qlen,
             unsigned char *r, int *rlen, int deadline_ms, uint16_t id,
             struct result *res)
{
	unsigned char frame[2 + QUERY_MAX];
	int fd, len, n, flags, left;
	double t0;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		res->error = "socket() failed";
		return -1;
	}

	flags = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, flags | O_NONBLOCK);

	t0 = now_ms();

	if (connect(fd, (const struct sockaddr *)srv, sizeof(*srv)) < 0 &&
	    errno != EINPROGRESS) {
		res->error = "tcp connect() failed";
		close(fd);
		return -1;
	}

	if (wait_fd(fd, POLLOUT, deadline_ms) < 0) {
		res->error = "tcp connect timed out";
		close(fd);
		return -1;
	}

	frame[0] = (unsigned char)(qlen >> 8);
	frame[1] = (unsigned char)(qlen & 0xFF);
	memcpy(frame + 2, q, (size_t)qlen);

	if (send(fd, frame, (size_t)qlen + 2, 0) != (ssize_t)(qlen + 2)) {
		res->error = "tcp send() failed";
		close(fd);
		return -1;
	}

	left = deadline_ms - (int)(now_ms() - t0);
	if (left <= 0 || wait_fd(fd, POLLIN, left) < 0) {
		res->error = "tcp no reply before deadline";
		close(fd);
		return -1;
	}

	/* Two-byte length prefix, then the message. Short reads are retried. */
	n = 0;
	while (n < 2) {
		len = (int)recv(fd, frame + n, (size_t)(2 - n), 0);
		if (len <= 0) {
			res->error = "tcp short length prefix";
			close(fd);
			return -1;
		}
		n += len;
	}

	len = (frame[0] << 8) | frame[1];
	if (len < 12 || len > RESPONSE_MAX) {
		res->error = "tcp bad length prefix";
		close(fd);
		return -1;
	}

	n = 0;
	while (n < len) {
		int got = (int)recv(fd, r + n, (size_t)(len - n), 0);
		if (got <= 0) {
			res->error = "tcp short reply";
			close(fd);
			return -1;
		}
		n += got;
	}

	res->rtt_ms = now_ms() - t0;
	*rlen = len;
	close(fd);

	return (uint16_t)(((r[0] << 8) | r[1])) == id ? 0 : -2;
}

/* ---------------------------------------------------------------- parse */

/* Returns 0 and advances *next past a (possibly compressed) name. */
static int
skip_name(const unsigned char *p, const unsigned char *end,
          const unsigned char **next)
{
	int guard = 0;

	while (p < end && guard++ < 128) {
		if ((*p & 0xC0) == 0xC0) {
			if (p + 1 >= end)
				return -1;
			*next = p + 2;
			return 0;
		}
		if (*p == 0) {
			*next = p + 1;
			return 0;
		}
		p += (size_t)*p + 1;
	}

	return -1;
}

static const char *
rcode_name(int rc)
{
	switch (rc) {
	case 0:  return "NOERROR";
	case 1:  return "FORMERR";
	case 2:  return "SERVFAIL";
	case 3:  return "NXDOMAIN";
	case 4:  return "NOTIMP";
	case 5:  return "REFUSED";
	default: return "OTHER";
	}
}

/* 0 on success; fills rcode / addresses. */
static int
parse_response(const unsigned char *r, int rlen, struct result *res)
{
	const unsigned char *p = r + 12, *end = r + rlen;
	int qd, an, i, rc, tc;

	if (rlen < 12)
		return -1;

	rc = r[3] & 0x0F;
	tc = (r[2] & 0x02) != 0;
	if (tc) {
		/* Caller retries over TCP; signal it. */
		return -2;
	}

	/* Only NOERROR carries usable records; everything else is no-answer. */
	qd = (r[4] << 8) | r[5];
	an = (r[6] << 8) | r[7];

	for (i = 0; i < qd; i++) {
		if (skip_name(p, end, &p) < 0 || p + 4 > end)
			return -1;
		p += 4;
	}

	for (i = 0; i < an; i++) {
		const unsigned char *rd;
		int type, cls, rdlen;

		if (skip_name(p, end, &p) < 0 || p + 10 > end)
			return -1;

		type = (p[0] << 8) | p[1];
		cls = (p[2] << 8) | p[3];
		rdlen = (p[8] << 8) | p[9];
		rd = p + 10;
		p = rd + rdlen;

		if (p > end)
			return -1;

		if (rc == 0 && type == 1 && cls == 1 && rdlen == 4 &&
		    res->naddr < MAX_ADDRS) {
			struct in_addr a;

			memcpy(&a.s_addr, rd, 4);
			inet_ntop(AF_INET, &a, res->addr[res->naddr],
			          INET_ADDRSTRLEN);
			res->naddr++;
		}
	}

	res->rcode = rcode_name(rc);
	return 0;
}

/* ---------------------------------------------------------------- main */

int
main(int argc, char **argv)
{
	struct sockaddr_in srv;
	struct in_addr cidr_net;
	unsigned char query[QUERY_MAX], resp[RESPONSE_MAX];
	const char *server = NULL, *domain = NULL, *cidr = NULL;
	const char *mode_s = "any";
	enum expect_mode mode = MODE_ANY;
	int port = 53, deadline_ms = DEF_DEADLINE_MS, have_cidr = 0;
	int prefix = 0, qlen, rlen = 0, opt;
	struct result res;
	uint16_t id;
	int i;

	memset(&res, 0, sizeof(res));
	res.rtt_ms = -1;
	res.rcode = "";
	res.error = "";
	res.cls = "";

	while ((opt = getopt(argc, argv, "s:p:d:m:c:t:h")) != -1) {
		switch (opt) {
		case 's': server = optarg; break;
		case 'p': port = atoi(optarg); break;
		case 'd': domain = optarg; break;
		case 'm': mode_s = optarg; break;
		case 'c': cidr = optarg; break;
		case 't': deadline_ms = atoi(optarg); break;
		default:
			usage();
			return 2;
		}
	}

	if (!server || !domain || port <= 0 || port > 65535) {
		usage();
		return 2;
	}
	if (deadline_ms < MIN_DEADLINE_MS || deadline_ms > MAX_DEADLINE_MS) {
		fprintf(stderr, "dnswatch-probe: deadline out of range\n");
		return 2;
	}
	if (!valid_domain(domain)) {
		fprintf(stderr, "dnswatch-probe: invalid domain\n");
		return 2;
	}

	if (!strcmp(mode_s, "in"))
		mode = MODE_IN;
	else if (!strcmp(mode_s, "not-in"))
		mode = MODE_NOT_IN;
	else if (!strcmp(mode_s, "any"))
		mode = MODE_ANY;
	else {
		fprintf(stderr, "dnswatch-probe: invalid mode\n");
		return 2;
	}

	memset(&srv, 0, sizeof(srv));
	srv.sin_family = AF_INET;
	srv.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, server, &srv.sin_addr) != 1) {
		fprintf(stderr, "dnswatch-probe: invalid server address\n");
		return 2;
	}

	if (cidr && *cidr) {
		if (parse_cidr(cidr, &cidr_net, &prefix) < 0) {
			fprintf(stderr, "dnswatch-probe: invalid cidr\n");
			return 2;
		}
		have_cidr = 1;
	}

	id = random_id();
	qlen = build_query(query, sizeof(query), domain, id);
	if (qlen < 0) {
		fprintf(stderr, "dnswatch-probe: domain too long\n");
		return 2;
	}

	if (udp_exchange(&srv, query, qlen, resp, &rlen, deadline_ms, id, &res) < 0) {
		res.cls = "timeout";
		goto emit;
	}

	opt = parse_response(resp, rlen, &res);

	if (opt == -2) {
		/* Truncated: ask again over TCP. */
		int t = tcp_exchange(&srv, query, qlen, resp, &rlen, deadline_ms, id, &res);

		if (t == -1) {
			res.cls = "timeout";
			goto emit;
		}
		if (t < 0) {
			res.cls = "no-answer";
			res.error = "tcp reply id mismatch";
			goto emit;
		}
		opt = parse_response(resp, rlen, &res);
	}

	if (opt < 0) {
		res.cls = "no-answer";
		res.error = "malformed reply";
		goto emit;
	}

	if (res.naddr == 0) {
		res.cls = "no-answer";
		goto emit;
	}

	/* Every A record must satisfy the expectation. */
	for (i = 0; i < res.naddr; i++) {
		struct in_addr a;
		int hit;

		inet_pton(AF_INET, res.addr[i], &a);

		if (!have_cidr || mode == MODE_ANY)
			continue;

		hit = cidr_match(&a, &cidr_net, prefix);

		if (mode == MODE_IN && !hit) {
			res.cls = "wrong-answer";
			goto emit;
		}
		if (mode == MODE_NOT_IN && hit) {
			res.cls = "wrong-answer";
			goto emit;
		}
	}

	res.ok = 1;

emit:
	printf("{\"ok\":%s,\"class\":\"%s\",\"rcode\":\"%s\",\"server\":\"%s\","
	       "\"port\":%d,\"domain\":\"%s\",\"rtt_ms\":%.1f,\"answers\":[",
	       res.ok ? "true" : "false", res.cls, res.rcode, server, port,
	       domain, res.rtt_ms);

	for (i = 0; i < res.naddr; i++)
		printf("%s\"%s\"", i ? "," : "", res.addr[i]);

	printf("],\"error\":\"%s\"}\n", res.error);

	return res.ok ? 0 : 1;
}
