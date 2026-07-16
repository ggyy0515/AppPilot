package transport

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/stretchr/testify/require"
)

func TestTCPDialConnectsAndClosesPerRequest(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, listener.Close()) })

	peerClosed := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			peerClosed <- acceptErr
			return
		}
		defer conn.Close()
		_, readErr := conn.Read(make([]byte, 1))
		peerClosed <- readErr
	}()

	deviceTransport, err := NewTCP("127.0.0.1")
	require.NoError(t, err)
	require.Equal(t, "tcp", deviceTransport.Name())
	conn, err := deviceTransport.Dial(context.Background(), "ignored", uint16(listener.Addr().(*net.TCPAddr).Port))
	require.NoError(t, err)
	require.NoError(t, conn.Close())

	select {
	case readErr := <-peerClosed:
		require.ErrorIs(t, readErr, io.EOF)
	case <-time.After(time.Second):
		t.Fatal("accepted connection was not closed")
	}
}

func TestNewTCPRejectsNonLoopbackHost(t *testing.T) {
	_, err := NewTCP("192.0.2.1")
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
}

func TestTCPDialMapsContextTimeout(t *testing.T) {
	deviceTransport := tcpTransport{
		host: "127.0.0.1",
		dialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	_, err := deviceTransport.Dial(ctx, "", 9876)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
}

func TestUSBSelectsMatchingPhysicalEntryAndCallerClosesConnection(t *testing.T) {
	client, server := net.Pipe()
	t.Cleanup(func() { _ = server.Close() })
	mux := &fakeMux{
		devices: []muxDevice{
			{UDID: "chosen", DeviceID: 7, ConnectionType: "Network"},
			{UDID: "other", DeviceID: 8, ConnectionType: "USB"},
			{UDID: "chosen", DeviceID: 9, ConnectionType: "USB"},
		},
		connection: client,
	}
	usb := newUSBWithMux(mux)
	require.Equal(t, "usb", usb.Name())

	conn, err := usb.Dial(context.Background(), "chosen", 9876)
	require.NoError(t, err)
	require.Equal(t, []connectCall{{deviceID: 9, port: 9876}}, mux.connects)
	require.False(t, mux.closed)
	require.NoError(t, conn.Close())

	_ = server.SetReadDeadline(time.Now().Add(time.Second))
	_, readErr := server.Read(make([]byte, 1))
	require.ErrorIs(t, readErr, io.EOF)
}

func TestUSBRejectsNetworkOnlyUsbmuxEntry(t *testing.T) {
	mux := &fakeMux{devices: []muxDevice{{UDID: "chosen", DeviceID: 7, ConnectionType: "Network"}}}
	usb := newUSBWithMux(mux)

	_, err := usb.Dial(context.Background(), "chosen", 9876)
	require.Equal(t, contract.TransportFailure, contract.CodeOf(err))
	require.True(t, mux.closed)
}

func TestUSBConnectFailureMapsAppNotReachableAndClosesMux(t *testing.T) {
	mux := &fakeMux{
		devices:    []muxDevice{{UDID: "chosen", DeviceID: 7, ConnectionType: "USB"}},
		connectErr: errors.New("device disconnected"),
	}
	usb := newUSBWithMux(mux)

	_, err := usb.Dial(context.Background(), "chosen", 9876)
	require.Equal(t, contract.AppNotReachable, contract.CodeOf(err))
	require.True(t, mux.closed)
}

func TestUSBCancellationClosesMuxAndWaitsForWorker(t *testing.T) {
	listStarted := make(chan struct{})
	mux := &fakeMux{listStarted: listStarted, blockListUntilClose: true}
	usb := newUSBWithMux(mux)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := usb.Dial(ctx, "chosen", 9876)
		done <- err
	}()

	select {
	case <-listStarted:
	case <-time.After(time.Second):
		t.Fatal("USB worker did not begin listing devices")
	}
	cancel()

	select {
	case err := <-done:
		require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
		require.True(t, mux.closed)
		require.True(t, mux.listReturned)
	case <-time.After(time.Second):
		t.Fatal("USB cancellation leaked its worker")
	}
}

func TestUSBAlreadyFinishedContextOverridesImmediateListResult(t *testing.T) {
	testCases := []struct {
		name       string
		newContext func() (context.Context, context.CancelFunc)
	}{
		{
			name: "canceled",
			newContext: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx, func() {}
			},
		},
		{
			name: "deadline",
			newContext: func() (context.Context, context.CancelFunc) {
				return context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
			},
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			for iteration := 0; iteration < 512; iteration++ {
				ctx, cancel := testCase.newContext()
				mux := &fakeMux{listErr: errors.New("immediate list failure")}
				usb := newUSBWithMux(mux)

				_, err := usb.Dial(ctx, "chosen", 9876)
				cancel()
				require.Equalf(t, contract.RequestTimeout, contract.CodeOf(err), "iteration %d", iteration)
			}
		})
	}
}

func TestUSBAlreadyFinishedContextClosesImmediateSuccessfulConnection(t *testing.T) {
	testCases := []struct {
		name       string
		newContext func() (context.Context, context.CancelFunc)
	}{
		{
			name: "canceled",
			newContext: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx, func() {}
			},
		},
		{
			name: "deadline",
			newContext: func() (context.Context, context.CancelFunc) {
				return context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
			},
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			for iteration := 0; iteration < 512; iteration++ {
				client, server := net.Pipe()
				ctx, cancel := testCase.newContext()
				mux := &fakeMux{
					devices:    []muxDevice{{UDID: "chosen", DeviceID: iteration + 1, ConnectionType: "USB"}},
					connection: client,
				}

				conn, err := newUSBWithMux(mux).Dial(ctx, "chosen", 9876)
				cancel()
				if conn != nil {
					_ = conn.Close()
				}
				require.Equalf(t, contract.RequestTimeout, contract.CodeOf(err), "iteration %d", iteration)

				_ = server.SetReadDeadline(time.Now().Add(time.Second))
				_, readErr := server.Read(make([]byte, 1))
				require.ErrorIsf(t, readErr, io.EOF, "iteration %d", iteration)
				_ = server.Close()
			}
		})
	}
}

func TestUSBResultFinalizationChecksFinishedContext(t *testing.T) {
	testCases := []struct {
		name       string
		newContext func() (context.Context, context.CancelFunc)
	}{
		{
			name: "canceled",
			newContext: func() (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx, func() {}
			},
		},
		{
			name: "deadline",
			newContext: func() (context.Context, context.CancelFunc) {
				return context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
			},
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name+"/success", func(t *testing.T) {
			client, server := net.Pipe()
			ctx, cancel := testCase.newContext()
			defer cancel()

			conn, err := finishUSBResult(ctx, usbDialResult{conn: client})
			require.Nil(t, conn)
			require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
			requirePeerClosed(t, server)
		})

		t.Run(testCase.name+"/error", func(t *testing.T) {
			ctx, cancel := testCase.newContext()
			defer cancel()

			conn, err := finishUSBResult(ctx, usbDialResult{err: contract.New(contract.TransportFailure, errors.New("list failed"))})
			require.Nil(t, conn)
			require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
		})
	}
}

func TestTCPConcurrentDialsOwnIndependentConnections(t *testing.T) {
	const dialCount = 32
	var mu sync.Mutex
	peers := make(map[net.Conn]net.Conn, dialCount)
	deviceTransport := tcpTransport{
		host: "127.0.0.1",
		dialContext: func(context.Context, string, string) (net.Conn, error) {
			client, server := net.Pipe()
			mu.Lock()
			peers[client] = server
			mu.Unlock()
			return client, nil
		},
	}

	connections := dialConcurrently(t, deviceTransport, dialCount)
	requireUniqueConnections(t, connections)

	require.NoError(t, connections[0].Close())
	requirePeerClosed(t, peers[connections[0]])
	requirePeerOpen(t, peers[connections[1]])

	for index := 1; index < dialCount; index++ {
		require.NoError(t, connections[index].Close())
		requirePeerClosed(t, peers[connections[index]])
	}
}

func TestUSBConcurrentDialsUseIndependentMuxesAndConnections(t *testing.T) {
	const dialCount = 32
	var mu sync.Mutex
	muxes := make([]*fakeMux, 0, dialCount)
	peers := make(map[net.Conn]net.Conn, dialCount)
	deviceTransport := usbTransport{
		openMux: func(context.Context) (usbMux, error) {
			client, server := net.Pipe()
			mux := &fakeMux{
				devices:    []muxDevice{{UDID: "chosen", DeviceID: 7, ConnectionType: "USB"}},
				connection: client,
			}
			mu.Lock()
			muxes = append(muxes, mux)
			peers[client] = server
			mu.Unlock()
			return mux, nil
		},
	}

	connections := dialConcurrently(t, deviceTransport, dialCount)
	requireUniqueConnections(t, connections)
	mu.Lock()
	require.Len(t, muxes, dialCount)
	requireUniqueMuxes(t, muxes)
	mu.Unlock()

	require.NoError(t, connections[0].Close())
	requirePeerClosed(t, peers[connections[0]])
	requirePeerOpen(t, peers[connections[1]])

	for index := 1; index < dialCount; index++ {
		require.NoError(t, connections[index].Close())
		requirePeerClosed(t, peers[connections[index]])
	}
}

func dialConcurrently(t *testing.T, deviceTransport DeviceTransport, count int) []net.Conn {
	t.Helper()
	type dialResult struct {
		conn net.Conn
		err  error
	}
	start := make(chan struct{})
	results := make(chan dialResult, count)
	for index := 0; index < count; index++ {
		go func() {
			<-start
			conn, err := deviceTransport.Dial(context.Background(), "chosen", 9876)
			results <- dialResult{conn: conn, err: err}
		}()
	}
	close(start)

	connections := make([]net.Conn, 0, count)
	for index := 0; index < count; index++ {
		select {
		case result := <-results:
			require.NoError(t, result.err)
			require.NotNil(t, result.conn)
			connections = append(connections, result.conn)
		case <-time.After(time.Second):
			t.Fatal("concurrent dial timed out")
		}
	}
	return connections
}

func requireUniqueConnections(t *testing.T, connections []net.Conn) {
	t.Helper()
	seen := make(map[net.Conn]struct{}, len(connections))
	for _, conn := range connections {
		_, exists := seen[conn]
		require.False(t, exists)
		seen[conn] = struct{}{}
	}
}

func requireUniqueMuxes(t *testing.T, muxes []*fakeMux) {
	t.Helper()
	seen := make(map[*fakeMux]struct{}, len(muxes))
	for _, mux := range muxes {
		_, exists := seen[mux]
		require.False(t, exists)
		seen[mux] = struct{}{}
	}
}

func requirePeerClosed(t *testing.T, peer net.Conn) {
	t.Helper()
	defer peer.Close()
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	_, err := peer.Read(make([]byte, 1))
	require.ErrorIs(t, err, io.EOF)
}

func requirePeerOpen(t *testing.T, peer net.Conn) {
	t.Helper()
	_ = peer.SetReadDeadline(time.Now().Add(10 * time.Millisecond))
	_, err := peer.Read(make([]byte, 1))
	var netError net.Error
	require.ErrorAs(t, err, &netError)
	require.True(t, netError.Timeout())
	require.NoError(t, peer.SetReadDeadline(time.Time{}))
}

type connectCall struct {
	deviceID int
	port     uint16
}

type fakeMux struct {
	mu                  sync.Mutex
	devices             []muxDevice
	listErr             error
	connectErr          error
	connection          net.Conn
	connects            []connectCall
	closed              bool
	listReturned        bool
	listStarted         chan struct{}
	blockListUntilClose bool
	closedSignal        chan struct{}
}

func (m *fakeMux) ListDevices() ([]muxDevice, error) {
	if m.blockListUntilClose {
		m.mu.Lock()
		if m.closedSignal == nil {
			m.closedSignal = make(chan struct{})
		}
		closedSignal := m.closedSignal
		m.mu.Unlock()
		if m.listStarted != nil {
			close(m.listStarted)
		}
		<-closedSignal
	} else if m.listStarted != nil {
		close(m.listStarted)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.listReturned = true
	return m.devices, m.listErr
}

func (m *fakeMux) Connect(deviceID int, port uint16) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.connects = append(m.connects, connectCall{deviceID: deviceID, port: port})
	return m.connectErr
}

func (m *fakeMux) ReleaseConnection() net.Conn {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.connection
}

func (m *fakeMux) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil
	}
	m.closed = true
	if m.closedSignal != nil {
		close(m.closedSignal)
	}
	return nil
}
