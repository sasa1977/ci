package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
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
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Dir = *dir

	err := cmd.Start()
	if err != nil {
		log.Fatal(err)
	}

	fmt.Printf("os_cmd: started\n")

	exitStatus := make(chan int)
	go awaitCommand(cmd, exitStatus)

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
		killCmd.Stdout = os.Stdout
		killCmd.Stderr = os.Stderr
		killCmd.Dir = cmd.Dir

		err := killCmd.Run()
		if err == nil {
			select {
			case exit := <-exitStatus:
				os.Exit(exit)

			case <-time.After(5 * time.Second):
			}
		} else {
			os.Stderr.WriteString(err.Error() + "\n")
		}
	}
	cmd.Process.Signal(syscall.SIGKILL)
	exit := <-exitStatus
	os.Exit(exit)
}

func awaitCommand(cmd *exec.Cmd, exitStatus chan int) {
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
		out, err := rdr.ReadString('\n')
		if err != nil || out == "stop\n" {
			break
		}
	}

	stdinDone <- true
}
