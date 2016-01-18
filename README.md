Epoll in Swift
==============

This is just an experience on using Swift in Linux to create an Epoll based server.

This is heavily based on the C Epoll server published [here](https://banu.com/blog/2/how-to-use-epoll-a-complete-example-in-c/).

Building
--------

To build enter:

  swift build

Running
-------

To run enter:

  .build/debug/EpollInSwift

Then start telnet on another terminal, for example:

  telnet 192.168.1.1 8080

If the connection is established successfully anything you time will be printed on the server.
