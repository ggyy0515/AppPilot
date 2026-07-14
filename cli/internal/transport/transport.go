package transport

import (
	"context"
	"net"
)

type DeviceTransport interface {
	Dial(ctx context.Context, deviceID string, port uint16) (net.Conn, error)
	Name() string
}
