package main

import (
	"bufio"
	"encoding/binary"
	"io"
	"io/ioutil"
	"os"
)

type outPayload struct {
	bytes []byte
	done  chan bool
}

type stdoutWriter chan outPayload

func (writer stdoutWriter) sendOutput(bytes []byte) {
	done := make(chan bool)
	writer <- outPayload{bytes, done}
	<-done
}

func (writer stdoutWriter) flush() {
	writer.sendOutput([]byte{})
}

func startStdoutWriter() stdoutWriter {
	writer := make(chan outPayload)

	go func() {
		for {
			payload := <-writer

			if len(payload.bytes) > 0 {
				binary.Write(os.Stdout, binary.BigEndian, int32(len(payload.bytes)))
				binary.Write(os.Stdout, binary.BigEndian, payload.bytes)
			}

			payload.done <- true
		}
	}()

	return writer
}

func startStdinReader() chan bool {
	stdinDone := make(chan bool)

	go func() {
		rdr := bufio.NewReader(os.Stdin)

		for {
			var messageSize int32
			err := binary.Read(rdr, binary.BigEndian, &messageSize)
			if err != nil {
				break
			}

			bytes, err := ioutil.ReadAll(io.LimitReader(rdr, int64(messageSize)))
			if err != nil || string(bytes) == "stop" {
				break
			}
		}

		stdinDone <- true
	}()

	return stdinDone
}
