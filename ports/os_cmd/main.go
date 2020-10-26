package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

func main() {
	dir := flag.String("dir", ".", "working directory")
	killCmd := flag.String("kill_cmd", "", "working directory")

	flag.Parse()
	args := flag.Args()

	cmd := exec.Command(args[0], args[1:]...)
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		writePacket(os.Stdout, []byte(fmt.Sprintf("not started %s", err)))
		os.Exit(-1)
	}

	reader := bufio.NewReader(stdoutPipe)
	cmd.Stderr = cmd.Stdout
	cmd.Dir = *dir

	err = cmd.Start()
	if err != nil {
		writePacket(os.Stdout, []byte(fmt.Sprintf("not started %s", err)))
		os.Exit(-1)
	}

	writePacket(os.Stdout, []byte("started"))

	exitStatus := make(chan int)
	go awaitCommand(cmd, reader, exitStatus)

	stdinDone := make(chan bool)
	go readStdin(stdinDone)

	select {
	case <-stdinDone:
		kill(cmd, killCmd, exitStatus)

	case exit := <-exitStatus:
		os.Exit(exit)
	}
}

func kill(cmd *exec.Cmd, killCmd *string, exitStatus chan int) {
	if *killCmd != "" {
		fields := strings.Fields(*killCmd)
		killCmd := exec.Command(fields[0], fields[1:]...)
		killCmd.Dir = cmd.Dir

		var buf bytes.Buffer
		killCmd.Stdout = &buf
		killCmd.Stderr = &buf

		err := killCmd.Start()
		if err == nil {
			select {
			case exit := <-exitStatus:
				killCmd.Wait()
				sendOutput(buf.Bytes())
				os.Exit(exit)

			case <-time.After(1 * time.Second):
				sendOutput(buf.Bytes())
				killCmd.Process.Kill()
			}
		} else {
			sendOutput([]byte(fmt.Sprintf("%s", err)))
		}
	}
	cmd.Process.Signal(syscall.SIGKILL)
	exit := <-exitStatus
	os.Exit(exit)
}

func awaitCommand(cmd *exec.Cmd, reader *bufio.Reader, exitStatus chan int) {
	for {
		s, err := reader.ReadString('\n')
		if err == nil {
			sendOutput([]byte(s))
		} else {
			break
		}
	}

	err := cmd.Wait()
	if err != nil {
		exitError, ok := err.(*exec.ExitError)

		if ok {
			var waitStatus syscall.WaitStatus
			waitStatus = exitError.Sys().(syscall.WaitStatus)
			exitStatus <- waitStatus.ExitStatus()
		} else {
			exitStatus <- 1
		}
	} else {
		exitStatus <- 0
	}
}

func readStdin(stdinDone chan bool) {
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
}
