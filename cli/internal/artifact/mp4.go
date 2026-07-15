package artifact

import (
	"encoding/binary"
	"errors"
	"io"
	"os"

	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

var compatibleMP4Brands = map[string]struct{}{
	"isom": {},
	"mp41": {},
	"mp42": {},
	"qt  ": {},
}

func ValidateMP4(path string) error {
	if err := validateMP4(path); err != nil {
		return contract.New(contract.RecordingNotAvailable, err)
	}
	return nil
}

func validateMP4(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() < 8 {
		return errors.New("invalid MP4 file")
	}

	fileSize := uint64(info.Size())
	var offset uint64
	boxIndex := 0
	hasCompatibleBrand := false
	hasMovieBox := false
	for offset < fileSize {
		boxSize, headerSize, kind, err := readMP4Box(file, offset, fileSize)
		if err != nil {
			return err
		}
		if boxIndex == 0 {
			if kind != "ftyp" {
				return errors.New("first MP4 box is not ftyp")
			}
			hasCompatibleBrand, err = readMP4Brands(file, offset+headerSize, boxSize-headerSize)
			if err != nil {
				return err
			}
		} else if kind == "moov" {
			hasMovieBox = true
		}
		offset += boxSize
		boxIndex++
	}
	if offset != fileSize || !hasCompatibleBrand || !hasMovieBox {
		return errors.New("incomplete MP4 structure")
	}
	return nil
}

func readMP4Box(file *os.File, offset, fileSize uint64) (uint64, uint64, string, error) {
	if fileSize-offset < 8 {
		return 0, 0, "", io.ErrUnexpectedEOF
	}
	var header [16]byte
	if _, err := file.ReadAt(header[:8], int64(offset)); err != nil {
		return 0, 0, "", err
	}
	size := uint64(binary.BigEndian.Uint32(header[:4]))
	headerSize := uint64(8)
	if size == 1 {
		if fileSize-offset < 16 {
			return 0, 0, "", io.ErrUnexpectedEOF
		}
		if _, err := file.ReadAt(header[8:16], int64(offset+8)); err != nil {
			return 0, 0, "", err
		}
		size = binary.BigEndian.Uint64(header[8:16])
		headerSize = 16
	} else if size == 0 {
		size = fileSize - offset
	}
	if size < headerSize || size > fileSize-offset {
		return 0, 0, "", errors.New("invalid MP4 box size")
	}
	return size, headerSize, string(header[4:8]), nil
}

func readMP4Brands(file *os.File, offset, payloadSize uint64) (bool, error) {
	if payloadSize < 8 || (payloadSize-8)%4 != 0 {
		return false, errors.New("invalid ftyp payload")
	}
	var brand [4]byte
	if _, err := file.ReadAt(brand[:], int64(offset)); err != nil {
		return false, err
	}
	_, compatible := compatibleMP4Brands[string(brand[:])]
	for position := uint64(8); position < payloadSize; position += 4 {
		if _, err := file.ReadAt(brand[:], int64(offset+position)); err != nil {
			return false, err
		}
		if _, ok := compatibleMP4Brands[string(brand[:])]; ok {
			compatible = true
		}
	}
	return compatible, nil
}
