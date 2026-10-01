module arena::udp_test;
import std::thread, arena::udp;

const int WAIT_TRIES @local = 500;

<* Loopback delivery is fast but not synchronous: poll up to ~0.5 s. *>
fn usz? recv_wait(UdpSock* s, char[] buf, NetAddr* from) @local
{
	for (int i = 0; i < WAIT_TRIES; i++)
	{
		if (try n = s.recv(buf, from)) return n;
		thread::sleep_ms(1);
	}
	return udp::NO_DATA~;
}

fn void loopback_round_trip() @test
{
	UdpSock a = udp::open(0, false)!!;
	defer a.close();
	UdpSock b = udp::open(0, false)!!;
	defer b.close();
	assert(a.local_port() != 0 && b.local_port() != 0);
	assert(a.local_port() != b.local_port());

	a.send(udp::loopback(b.local_port()), "hola arena")!!;
	char[64] buf;
	NetAddr from;
	usz n = recv_wait(&b, &buf, &from)!!;
	assert((String)buf[:n] == "hola arena");
	assert(from.equals(udp::loopback(a.local_port())));

	// Reply to the reported sender.
	b.send(from, "pong")!!;
	n = recv_wait(&a, &buf, null)!!;
	assert((String)buf[:n] == "pong");
}

fn void recv_empty_is_no_data() @test
{
	UdpSock s = udp::open(0, false)!!;
	defer s.close();
	char[16] buf;
	assert(@catch(s.recv(&buf, null)) == udp::NO_DATA);
}

fn void dead_peer_is_no_data() @test
{
	UdpSock a = udp::open(0, false)!!;
	defer a.close();
	UdpSock gone = udp::open(0, false)!!;
	ushort dead_port = gone.local_port();
	gone.close();
	gone.close(); // idempotent

	// Windows answers with ICMP port-unreachable -> WSAECONNRESET on the next recvfrom.
	a.send(udp::loopback(dead_port), "anyone?")!!;
	thread::sleep_ms(20);
	char[16] buf;
	assert(@catch(a.recv(&buf, null)) == udp::NO_DATA);
}

fn void oversized_datagram_is_truncated() @test
{
	UdpSock a = udp::open(0, false)!!;
	defer a.close();
	UdpSock b = udp::open(0, false)!!;
	defer b.close();
	char[100] big;
	big[..] = 'z';
	a.send(udp::loopback(b.local_port()), &big)!!;
	char[10] small;
	usz n = recv_wait(&b, &small, null)!!;
	assert(n == small.len && small[^1] == 'z');
	assert(@catch(b.recv(&small, null)) == udp::NO_DATA);
}

fn void broadcast_needs_opt_in() @test
{
	UdpSock plain = udp::open(0, false)!!;
	defer plain.close();
	assert(@catch(plain.send(udp::broadcast(plain.local_port()), "x")) == udp::SEND_FAILED);
	UdpSock caster = udp::open(0, true)!!;
	defer caster.close();
	caster.send(udp::broadcast(caster.local_port()), "x")!!;
}

fn void bind_conflict_fails() @test
{
	UdpSock a = udp::open(0, false)!!;
	defer a.close();
	assert(@catch(udp::open(a.local_port(), false)) == udp::BIND_FAILED);
}

fn void parse_valid_addresses() @test
{
	NetAddr a = udp::parse_addr("192.168.1.20", 27960)!!;
	assert(a.ip == 0xC0A8_0114 && a.port == 27960);
	a = udp::parse_addr("192.168.1.20:27961", 27960)!!;
	assert(a.ip == 0xC0A8_0114 && a.port == 27961);
	a = udp::parse_addr(" 10.0.0.255:5 ", 1)!!;
	assert(a.ip == 0x0A00_00FF && a.port == 5);
	a = udp::parse_addr("0.0.0.0:65535", 1)!!;
	assert(a.ip == 0 && a.port == 65535);
	a = udp::parse_addr("localhost", 27960)!!;
	assert(a.equals(udp::loopback(27960)));
	a = udp::parse_addr("localhost:1234", 27960)!!;
	assert(a.equals(udp::loopback(1234)));
}

fn void parse_rejects_garbage() @test
{
	String[*] bad = {
		"", "   ", ":27960", "256.1.1.1", "1.2.3", "1.2.3.4.5", "1..2.3", ".1.2.3",
		"1.2.3.", "0001.2.3.4", "1.2.3.4:", "1.2.3.4:0", "1.2.3.4:70000", "1.2.3.4:http",
		"1.2.3.4:+80", "no-such-host.invalid",
	};
	foreach (s : bad)
	{
		assert(@catch(udp::parse_addr(s, 27960)) == udp::BAD_ADDRESS, "accepted '%s'", s);
	}
	// A valid host still needs a non-zero port from somewhere.
	assert(@catch(udp::parse_addr("1.2.3.4", 0)) == udp::BAD_ADDRESS);
}

fn void addr_helpers() @test
{
	@pool()
	{
		assert(udp::loopback(27960).tstr() == "127.0.0.1:27960");
		assert(udp::broadcast(1).tstr() == "255.255.255.255:1");
		NetAddr a = { 0xC0A8_0114, 80 };
		assert(a.tstr() == "192.168.1.20:80");
	};
	assert(!udp::loopback(1).equals(udp::loopback(2)));
	assert(!udp::loopback(1).equals(udp::broadcast(1)));
}
