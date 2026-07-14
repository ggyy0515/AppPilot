package transport

import (
	"context"
	"errors"
	"net"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

type muxDevice struct {
	UDID           string
	DeviceID       int
	ConnectionType string
}

type usbMux interface {
	ListDevices() ([]muxDevice, error)
	Connect(deviceID int, port uint16) error
	ReleaseConnection() net.Conn
	Close() error
}

type usbTransport struct {
	openMux func(context.Context) (usbMux, error)
}

type usbDialResult struct {
	conn net.Conn
	err  error
}

func NewUSB() DeviceTransport {
	return usbTransport{openMux: openIOSMux}
}

func newUSBWithMux(mux usbMux) DeviceTransport {
	return usbTransport{openMux: func(context.Context) (usbMux, error) { return mux, nil }}
}

func (t usbTransport) Dial(ctx context.Context, deviceID string, port uint16) (net.Conn, error) {
	results := make(chan usbDialResult, 1)
	opened := make(chan usbMux, 1)
	go func() {
		mux, err := t.openMux(ctx)
		if err != nil {
			results <- usbDialResult{err: contract.New(contract.TransportFailure, err)}
			return
		}
		opened <- mux
		conn, err := connectUSB(mux, deviceID, port)
		results <- usbDialResult{conn: conn, err: err}
	}()

	var active usbMux
	ctxDone := ctx.Done()
	canceled := false
	for {
		select {
		case active = <-opened:
			if canceled {
				_ = active.Close()
			}
		case result := <-results:
			return finishUSBResult(ctx, result)
		case <-ctxDone:
			canceled = true
			ctxDone = nil
			if active != nil {
				_ = active.Close()
			}
		}
	}
}

func finishUSBResult(ctx context.Context, result usbDialResult) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		if result.conn != nil {
			_ = result.conn.Close()
		}
		return nil, contract.New(contract.RequestTimeout, err)
	}
	return result.conn, result.err
}

func (usbTransport) Name() string {
	return "usb"
}

func connectUSB(mux usbMux, udid string, port uint16) (net.Conn, error) {
	devices, err := mux.ListDevices()
	if err != nil {
		_ = mux.Close()
		return nil, contract.New(contract.TransportFailure, err)
	}
	var match *muxDevice
	for i := range devices {
		entry := &devices[i]
		if entry.UDID == udid && entry.ConnectionType == "USB" {
			match = entry
			break
		}
	}
	if match == nil {
		_ = mux.Close()
		return nil, contract.New(contract.TransportFailure, errors.New("selected UDID has no USB usbmux entry"))
	}
	if err := mux.Connect(match.DeviceID, port); err != nil {
		_ = mux.Close()
		return nil, contract.New(contract.AppNotReachable, err)
	}
	conn := mux.ReleaseConnection()
	if conn == nil {
		_ = mux.Close()
		return nil, contract.New(contract.TransportFailure, errors.New("usbmux returned no connected socket"))
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

type iosMux struct {
	raw ios.DeviceConnectionInterface
	mux *ios.UsbMuxConnection
}

func openIOSMux(ctx context.Context) (usbMux, error) {
	raw, err := ios.NewDeviceConnection(ios.GetUsbmuxdSocket())
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = raw.Conn().SetDeadline(deadline)
	}
	return &iosMux{raw: raw, mux: ios.NewUsbMuxConnection(raw)}, nil
}

func (m *iosMux) ListDevices() ([]muxDevice, error) {
	devices, err := m.mux.ListDevices()
	if err != nil {
		return nil, err
	}
	result := make([]muxDevice, 0, len(devices.DeviceList))
	for _, entry := range devices.DeviceList {
		result = append(result, muxDevice{
			UDID:           entry.Properties.SerialNumber,
			DeviceID:       entry.DeviceID,
			ConnectionType: entry.Properties.ConnectionType,
		})
	}
	return result, nil
}

func (m *iosMux) Connect(deviceID int, port uint16) error {
	return m.mux.Connect(deviceID, port)
}

func (m *iosMux) ReleaseConnection() net.Conn {
	return m.mux.ReleaseDeviceConnection().Conn()
}

func (m *iosMux) Close() error {
	return m.raw.Close()
}
