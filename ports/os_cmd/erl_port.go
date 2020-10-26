package main

import (
	"bufio"
	"encoding/binary"
	"io"
	"io/ioutil"
	"os"
)

func sendOutput(output []byte) {
	writePacket(os.Stdout, erlangTermBytes(tuple(atom("output"), erlangBinary{output})))
}

func writePacket(w io.Writer, bytes []byte) {
	binary.Write(w, binary.BigEndian, int32(len(bytes)))
	binary.Write(w, binary.BigEndian, bytes)
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
