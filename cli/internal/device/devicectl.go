package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/yangy003/ap-ios-debug-system/internal/contract"
)

const devicectlJSONVersion = 3

type Discoverer struct {
	runner  Runner
	tempDir string
}

func NewDiscoverer(runner Runner, tempDir string) *Discoverer {
	return &Discoverer{runner: runner, tempDir: tempDir}
}

func (d *Discoverer) List(ctx context.Context) ([]Device, error) {
	path, err := tempJSONPath(d.tempDir)
	if err != nil {
		return nil, contract.New(contract.IOFailure, err)
	}
	defer os.Remove(path)
	if err := d.runner.Run(ctx, "xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", path); err != nil {
		return nil, mapDeviceCtlError(err)
	}
	return parseList(path)
}

func (d *Discoverer) Resolve(ctx context.Context, selector Selector) (Device, error) {
	devices, err := d.List(ctx)
	if err != nil {
		return Device{}, err
	}
	return resolve(devices, selector)
}

func (d *Discoverer) CheckReady(ctx context.Context, selected Device) error {
	if selected.PairingState != "paired" {
		return contract.New(contract.DeviceUntrusted, nil)
	}
	path, err := tempJSONPath(d.tempDir)
	if err != nil {
		return contract.New(contract.IOFailure, err)
	}
	defer os.Remove(path)
	if err := d.runner.Run(ctx, "xcrun", "devicectl", "device", "info", "lockState", "--device", selected.Identifier, "--quiet", "--json-output", path); err != nil {
		return mapDeviceCtlError(err)
	}
	locked, err := parseLockState(path, selected.Identifier)
	if err != nil {
		return err
	}
	if locked {
		return contract.New(contract.DeviceLocked, nil)
	}
	return nil
}

func tempJSONPath(directory string) (string, error) {
	file, err := os.CreateTemp(directory, "ap-ios-debug-devicectl-*.json")
	if err != nil {
		return "", err
	}
	path := file.Name()
	if err := file.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

type envelopeInfo struct {
	CommandType string `json:"commandType"`
	JSONVersion int    `json:"jsonVersion"`
	Outcome     string `json:"outcome"`
}

type listEnvelope struct {
	Info   envelopeInfo `json:"info"`
	Result struct {
		Devices []struct {
			ConnectionProperties struct {
				PairingState  string `json:"pairingState"`
				TransportType string `json:"transportType"`
			} `json:"connectionProperties"`
			DeviceProperties struct {
				Name      string `json:"name"`
				OSVersion string `json:"osVersionNumber"`
			} `json:"deviceProperties"`
			HardwareProperties struct {
				DeviceType string `json:"deviceType"`
				Platform   string `json:"platform"`
				Reality    string `json:"reality"`
				UDID       string `json:"udid"`
			} `json:"hardwareProperties"`
			Identifier string `json:"identifier"`
		} `json:"devices"`
	} `json:"result"`
}

func parseList(path string) ([]Device, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, contract.New(contract.IOFailure, err)
	}
	var envelope listEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, contract.New(contract.ProtocolMismatch, err)
	}
	if err := validateEnvelope(envelope.Info, "devicectl.list.devices"); err != nil {
		return nil, err
	}
	devices := make([]Device, 0, len(envelope.Result.Devices))
	for _, record := range envelope.Result.Devices {
		if record.HardwareProperties.Platform != "iOS" || record.HardwareProperties.Reality != "physical" {
			continue
		}
		if record.ConnectionProperties.TransportType != "" &&
			(strings.TrimSpace(record.Identifier) == "" || strings.TrimSpace(record.HardwareProperties.UDID) == "") {
			return nil, contract.New(contract.ProtocolMismatch, errors.New("available physical device is missing an identifier"))
		}
		devices = append(devices, Device{
			Identifier: record.Identifier, UDID: record.HardwareProperties.UDID,
			Name: record.DeviceProperties.Name, Platform: record.HardwareProperties.Platform,
			DeviceType: record.HardwareProperties.DeviceType, OSVersion: record.DeviceProperties.OSVersion,
			PairingState:  record.ConnectionProperties.PairingState,
			TransportType: record.ConnectionProperties.TransportType,
			Available:     record.ConnectionProperties.TransportType != "",
		})
	}
	return devices, nil
}

type lockEnvelope struct {
	Info   envelopeInfo `json:"info"`
	Result struct {
		DeviceIdentifier string `json:"deviceIdentifier"`
		PasscodeRequired *bool  `json:"passcodeRequired"`
	} `json:"result"`
}

func parseLockState(path, identifier string) (bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return false, contract.New(contract.IOFailure, err)
	}
	var envelope lockEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return false, contract.New(contract.ProtocolMismatch, err)
	}
	if err := validateEnvelope(envelope.Info, "devicectl.device.info.lockState"); err != nil {
		return false, err
	}
	if envelope.Result.DeviceIdentifier != identifier {
		return false, contract.New(contract.ProtocolMismatch, errors.New("devicectl lock response identified another device"))
	}
	if envelope.Result.PasscodeRequired == nil {
		return false, contract.New(contract.ProtocolMismatch, errors.New("devicectl lock response omitted passcode state"))
	}
	return *envelope.Result.PasscodeRequired, nil
}

func validateEnvelope(info envelopeInfo, command string) error {
	if info.JSONVersion != devicectlJSONVersion {
		return contract.New(contract.ProtocolMismatch, fmt.Errorf("devicectl JSON version %d is unsupported", info.JSONVersion))
	}
	if info.CommandType != command || info.Outcome != "success" {
		return contract.New(contract.ProtocolMismatch, errors.New("unexpected devicectl response envelope"))
	}
	return nil
}

func mapDeviceCtlError(err error) error {
	var stable *contract.Error
	if errors.As(err, &stable) && contract.CodeOf(err) == contract.ToolMissing {
		return err
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "pair") || strings.Contains(message, "trust") {
		return contract.New(contract.DeviceUntrusted, err)
	}
	if strings.Contains(message, "lock") || strings.Contains(message, "passcode") {
		return contract.New(contract.DeviceLocked, err)
	}
	return contract.New(contract.TransportFailure, err)
}
