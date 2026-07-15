package device

import (
	"context"

	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

type Runner interface {
	Run(ctx context.Context, executable string, args ...string) error
}

type Device struct {
	Identifier    string `json:"identifier"`
	UDID          string `json:"udid"`
	Name          string `json:"name"`
	Platform      string `json:"platform"`
	DeviceType    string `json:"device_type"`
	OSVersion     string `json:"os_version"`
	PairingState  string `json:"pairing_state"`
	TransportType string `json:"transport_type"`
	Available     bool   `json:"available"`
	Locked        *bool  `json:"locked,omitempty"`
}

type Selector struct {
	UDID        string
	Name        string
	AllowSingle bool
}

func resolve(devices []Device, selector Selector) (Device, error) {
	matches := make([]Device, 0, len(devices))
	for _, candidate := range devices {
		if !candidate.Available {
			continue
		}
		switch {
		case selector.UDID != "" && candidate.UDID == selector.UDID:
			matches = append(matches, candidate)
		case selector.UDID == "" && selector.Name != "" && candidate.Name == selector.Name:
			matches = append(matches, candidate)
		case selector.UDID == "" && selector.Name == "" && selector.AllowSingle:
			matches = append(matches, candidate)
		}
	}
	if len(matches) == 0 {
		return Device{}, contract.New(contract.NoDevice, nil)
	}
	if len(matches) != 1 {
		return Device{}, contract.New(contract.MultipleDevices, nil)
	}
	return matches[0], nil
}
