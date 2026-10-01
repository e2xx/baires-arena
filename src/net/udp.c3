// Non-blocking IPv4 UDP sockets with explicit addresses (bind, sendto/recvfrom, broadcast).
// std::net only offers connected UDP, so sendto/recvfrom/WSAIoctl are declared here; the rest
// (socket, bind, setsockopt, getaddrinfo, WSAStartup, non-blocking, close) comes from
// std::net::os. sockaddr_in layout below is the Windows/Linux one (BSD/macOS differ).
module arena::udp;
import std::net, std::net::os, std::os, libc;

faultdef NET_INIT_FAILED, SOCKET_FAILED, BIND_FAILED, SEND_FAILED, NO_DATA, BAD_ADDRESS;

const uint IP_ANY = 0;
const uint IP_LOOPBACK = 0x7F00_0001;
const uint IP_BROADCAST = 0xFFFF_FFFF;

<* IPv4 endpoint, both fields in host byte order (127.0.0.1 == 0x7F000001). *>
struct NetAddr
{
	uint ip;
	ushort port;
}

struct UdpSock
{
	NativeSocket fd;
	ushort port;    // actual bound port (resolved when 0 was requested)
	bool live;
}

struct SockAddrIn @local
{
	ushort family;
	UShortBE port;
	UIntBE addr;
	char[8] zero;
}

const AIProtocol IPPROTO_UDP @local = (AIProtocol)17;
const CInt ENABLED @local = 1;
const uint SIO_UDP_CONNRESET @local = 0x9800_000C; // _WSAIOW(IOC_VENDOR, 12)

extern fn CInt sys_sendto(NativeSocket s, char* buf, CInt len, CInt flags, SockAddrIn* to, CInt to_len)
	@cname("sendto") @feat(WIN32) @local;
extern fn CInt sys_recvfrom(NativeSocket s, char* buf, CInt len, CInt flags, SockAddrIn* from, CInt* from_len)
	@cname("recvfrom") @feat(WIN32) @local;
extern fn CInt wsa_ioctl(NativeSocket s, uint code, void* in_buf, uint in_len, void* out_buf, uint out_len,
	uint* returned, void* overlapped, void* completion) @cname("WSAIoctl") @feat(WIN32) @local;

extern fn sz sys_sendto(NativeSocket s, char* buf, usz len, CInt flags, SockAddrIn* to, CUInt to_len)
	@cname("sendto") @feat(POSIX) @local;
extern fn sz sys_recvfrom(NativeSocket s, char* buf, usz len, CInt flags, SockAddrIn* from, CUInt* from_len)
	@cname("recvfrom") @feat(POSIX) @local;

// ---------------------------------------------------------------- addresses

fn NetAddr loopback(ushort port) => { IP_LOOPBACK, port };

fn NetAddr broadcast(ushort port) => { IP_BROADCAST, port };

<* "a.b.c.d:port" in the temp allocator. *>
fn String NetAddr.tstr(&self)
{
	return string::tformat("%d.%d.%d.%d:%d", self.ip >> 24, (self.ip >> 16) & 0xFF,
		(self.ip >> 8) & 0xFF, self.ip & 0xFF, self.port);
}

fn bool NetAddr.equals(&self, NetAddr o) => self.ip == o.ip && self.port == o.port;

<*
 Accepts "a.b.c.d", "host" and either with ":port". Anything made only of digits and dots must
 be a valid dotted quad; other names resolve through getaddrinfo (first IPv4 result).
 @return? BAD_ADDRESS : "malformed, port 0 or unresolvable"
*>
fn NetAddr? parse_addr(String s, ushort default_port)
{
	String host = s.trim();
	ushort port = default_port;
	if (try colon = host.rindex_of_char(':'))
	{
		port = parse_port(host[colon + 1..])!;
		host = host[:colon];
	}
	if (!host.len || !port) return BAD_ADDRESS~;
	if (is_numeric(host)) return { parse_quad(host)!, port };
	return { resolve(host)!, port };
}

fn bool is_numeric(String s) @local
{
	foreach (c : s)
	{
		if (!c.is_digit() && c != '.') return false;
	}
	return true;
}

fn ushort? parse_port(String s) @local
{
	if (!s.len) return BAD_ADDRESS~;
	foreach (c : s)
	{
		if (!c.is_digit()) return BAD_ADDRESS~;
	}
	return s.to_ushort() ?? BAD_ADDRESS~!;
}

<* Strict "a.b.c.d": four 1-3 digit octets, each <= 255. *>
fn uint? parse_quad(String s) @local
{
	uint ip;
	uint octet;
	int digits;
	int dots;
	foreach (c : s)
	{
		if (c == '.')
		{
			if (!digits || dots == 3) return BAD_ADDRESS~;
			ip = ip << 8 | octet;
			octet = 0;
			digits = 0;
			dots++;
			continue;
		}
		if (digits == 3) return BAD_ADDRESS~;
		octet = octet * 10 + (c - '0');
		digits++;
		if (octet > 255) return BAD_ADDRESS~;
	}
	if (!digits || dots != 3) return BAD_ADDRESS~;
	return ip << 8 | octet;
}

fn uint? resolve(String host) @local
{
	AddrInfo* list = net::addrinfo(host, 0, os::AF_INET, os::SOCK_DGRAM) ?? BAD_ADDRESS~!;
	defer os::freeaddrinfo(list);
	for (AddrInfo* ai = list; ai; ai = ai.ai_next)
	{
		if (ai.ai_family != os::AF_INET) continue;
		return ((SockAddrIn*)ai.ai_addr).addr.val;
	}
	return BAD_ADDRESS~;
}

fn SockAddrIn to_sockaddr(NetAddr a) @local
{
	return { .family = (ushort)os::AF_INET, .port = { .val = a.port }, .addr = { .val = a.ip } };
}

// ---------------------------------------------------------------- sockets

<* Winsock needs WSAStartup (lazy, idempotent) before any socket call; no-op elsewhere. *>
fn void? net_init() @local
{
	$if env::WIN32:
		if (catch os::start_wsa()) return NET_INIT_FAILED~;
	$endif
}

fn bool enable_opt(NativeSocket fd, CInt opt) @local
{
	CInt on = ENABLED;
	return os::setsockopt(fd, os::SOL_SOCKET, opt, &on, CInt::size) == 0;
}

<*
 Windows reports an ICMP port-unreachable (peer gone) as WSAECONNRESET on the next recvfrom.
 Best effort: recv also maps that error to NO_DATA.
*>
fn void disable_connreset(NativeSocket fd) @local @feat(WIN32)
{
	uint off = 0;
	uint returned;
	wsa_ioctl(fd, SIO_UDP_CONNRESET, &off, uint::size, null, 0, &returned, null, null);
}

<*
 Non-blocking UDP socket bound to 0.0.0.0:port (0 = ephemeral, see local_port()).
*>
fn UdpSock? open(ushort port, bool allow_broadcast)
{
	net_init()!;
	NativeSocket fd = os::socket(os::AF_INET, os::SOCK_DGRAM, IPPROTO_UDP);
	if (!fd.is_valid()) return SOCKET_FAILED~;
	defer catch (void)fd.close();

	if (catch fd.set_non_blocking(true)) return SOCKET_FAILED~;
	if (allow_broadcast && !enable_opt(fd, os::SO_BROADCAST)) return SOCKET_FAILED~;
	$if env::WIN32:
		disable_connreset(fd);
	$endif

	SockAddrIn sa = to_sockaddr({ IP_ANY, port });
	if (os::bind(fd, (SockAddrPtr)&sa, SockAddrIn::size)) return BIND_FAILED~;
	Socklen_t len = SockAddrIn::size;
	if (os::getsockname(fd, (SockAddrPtr)&sa, &len)) return BIND_FAILED~;
	return { .fd = fd, .port = sa.port.val, .live = true };
}

<*
 Sends one datagram. Fails (SEND_FAILED) on a full send buffer too: it's UDP, drop it.
 @require self.live : "socket is closed"
*>
fn void? UdpSock.send(&self, NetAddr to, char[] data)
{
	SockAddrIn sa = to_sockaddr(to);
	$if env::WIN32:
		sz sent = sys_sendto(self.fd, data.ptr, (CInt)data.len, 0, &sa, (CInt)SockAddrIn::size);
	$else
		sz sent = sys_sendto(self.fd, data.ptr, (usz)data.len, 0, &sa, (CUInt)SockAddrIn::size);
	$endif
	if (sent != data.len) return SEND_FAILED~;
}

<*
 Next pending datagram into `buf`; a larger one is truncated to buf.len on every platform.
 @param [out] from : "sender address; may be null"
 @require self.live : "socket is closed"
 @return? NO_DATA : "nothing pending (also for Windows' ICMP-unreachable WSAECONNRESET)"
*>
fn usz? UdpSock.recv(&self, char[] buf, NetAddr* from)
{
	SockAddrIn sa;
	$if env::WIN32:
		CInt len = SockAddrIn::size;
		sz got = sys_recvfrom(self.fd, buf.ptr, (CInt)buf.len, 0, &sa, &len);
	$else
		CUInt len = SockAddrIn::size;
		sz got = sys_recvfrom(self.fd, buf.ptr, (usz)buf.len, 0, &sa, &len);
	$endif
	if (got < 0) got = recv_error(buf.len)!;
	if (from) *from = { sa.addr.val, sa.port.val };
	return (usz)got;
}

<* Maps a failed recvfrom: would-block / peer-gone -> NO_DATA, oversized -> truncated length. *>
fn sz? recv_error(sz truncated) @local
{
	$if env::WIN32:
		switch (win32::wsaGetLastError())
		{
			case EWOULDBLOCK:
			case ECONNRESET:
				return NO_DATA~;
			case EMSGSIZE:
				return truncated;
			default:
				return SOCKET_FAILED~;
		}
	$else
		Errno err = libc::errno();
		if (err == EAGAIN || err == EWOULDBLOCK || err == ECONNREFUSED) return NO_DATA~;
		return SOCKET_FAILED~;
	$endif
}

fn ushort UdpSock.local_port(&self) => self.port;

<* Idempotent. *>
fn void UdpSock.close(&self)
{
	if (!self.live) return;
	(void)self.fd.close();
	self.live = false;
}
