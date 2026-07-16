package transport

import (
	"context"
	"errors"
	"net"
	"strconv"

	"github.com/ggyy0515/AppPilot/internal/contract"
)

type tcpTransport struct {
	host        string
	dialContext func(context.Context, string, string) (net.Conn, error)
}

func NewTCP(host string) (DeviceTransport, error) {
	addresses, err := net.DefaultResolver.LookupIPAddr(context.Background(), host)
	if err != nil || len(addresses) == 0 {
		return nil, contract.New(contract.ConfigInvalid, errors.New("TCP host must resolve to a loopback address"))
	}
	for _, address := range addresses {
		if !address.IP.IsLoopback() {
			return nil, contract.New(contract.ConfigInvalid, errors.New("TCP host must resolve only to loopback addresses"))
		}
	}

	dialer := &net.Dialer{}
	return tcpTransport{host: host, dialContext: dialer.DialContext}, nil
}

func (t tcpTransport) Dial(ctx context.Context, _ string, port uint16) (net.Conn, error) {
	conn, err := t.dialContext(ctx, "tcp", net.JoinHostPort(t.host, strconv.Itoa(int(port))))
	if err == nil {
		return conn, nil
	}
	var netError net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) || errors.As(err, &netError) && netError.Timeout() {
		return nil, contract.New(contract.RequestTimeout, err)
	}
	return nil, contract.New(contract.AppNotReachable, err)
}

func (tcpTransport) Name() string {
	return "tcp"
}
