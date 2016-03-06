import Foundation
import Glibc
import GlibcExtras

enum SocketError: ErrorType {
  case GetAddress(String?)
  case Create
  case Bind
  case FlagSet
  case Listen
}

class Socket {
  let port: String

  private var _socket: Int32
  var socket: Int32 { 
    get {
      return self._socket 
    }
  }

  init(port: String) throws {
    self.port = port
    self._socket = createAndBind(port)
  }

  deinit {
    close(self._socket);
  }

  private func createAndBind(port: String) throws -> Int32 {
    let hints = UnsafeMutablePointer<addrinfo>.alloc(1)
    defer { hints.dealloc(1) }

    hints.memory.ai_family = AF_UNSPEC
    hints.memory.ai_socktype = unsafeBitCast(SOCK_STREAM, Int32.self)
    hints.memory.ai_flags = AI_PASSIVE

    var result = UnsafeMutablePointer<addrinfo>()
    defer { freeaddrinfo(result) }
    let res = getaddrinfo(nil, port, hints, &result)

    print(res)
    if res != 0 {
      throw SocketError.GetAddress(String.fromCString(gai_strerror(res)))
    }

    var sfd:Int32 = -1
    var rp = result;
    repeat {
      defer { rp = UnsafeMutablePointer<addrinfo>(rp.memory.ai_next) }

      sfd = Glibc.socket(rp.memory.ai_family, rp.memory.ai_socktype, rp.memory.ai_protocol)

      if sfd == -1 { 
        throw SocketError.Create
      }

      let s = bind(sfd, rp.memory.ai_addr, rp.memory.ai_addrlen)
      if s == 0 { 
        print("Socket bound successfully")
        break 
      }
      
      close(sfd)
      sfd = -1
    } while rp != nil
    
    if sfd == -1 {
      throw SocketError.Bind
    }

    return sfd
  }

  func makeNonBlocking() throws {
    let flags = fcntl(self.socket, F_GETFL, 0)
    if flags == -1 {
      print("Unable to get socket flags")
      throw SocketError.FlagSet
    }

    let newFlags = flags | O_NONBLOCK
    let s = fcntl(self.socket, F_SETFL, newFlags)
    if s == -1 {
      print("Unable to set non-blocking flag")
      throw SocketError.FlagSet
    }
  }

  func listen() throws {
    if listen(sfd, SOMAXCONN) == -1 {
      throw SocketError.Listen
    }
  }
}

let socket: Socket?
do {
  socket = try Socket(port: "8080")
  try socket.makeNonBlocking() 
  try socket.listen()
} catch _ {
    fatalError("Unable to create or configure socket")
}
defer { socket.close() }

let efd = epoll_create1(0)
if efd == -1 {
  fatalError("epoll_create")
}

let event = UnsafeMutablePointer<epoll_event>.alloc(1)
defer { event.dealloc(1) }

event.memory.data.fd = sfd
event.memory.events = unsafeBitCast(EPOLLIN, UInt32.self) | unsafeBitCast(EPOLLET, UInt32.self)

if epoll_ctl(efd, EPOLL_CTL_ADD, sfd, event) == -1 {
  fatalError("epoll_ctl")
}

let MaxEvents:Int32 = 64

// Buffer where events are returned
let events = UnsafeMutablePointer<epoll_event>.alloc(Int(MaxEvents))
defer { events.dealloc(Int(MaxEvents)) }

/* The event loop */
var n = 0
while true {
  n = Int(epoll_wait(efd, events, MaxEvents, -1))
  for i in 0..<n {
    let ev = events[i]
    if ev.events & unsafeBitCast(EPOLLERR, UInt32.self) != 0 || 
       ev.events & unsafeBitCast(EPOLLHUP, UInt32.self) != 0 ||
       ev.events & unsafeBitCast(EPOLLIN, UInt32.self) == 0 {
      print("epoll error")
      close(ev.data.fd)
      continue
    }
    else if sfd == ev.data.fd {
      while true {
        let in_addr = UnsafeMutablePointer<sockaddr>.alloc(1)
        defer { in_addr.dealloc(1) }
        var in_len:UInt32 = UInt32(sizeof(sockaddr))
        let infd = accept(sfd, in_addr, &in_len)
        if infd == -1 {
          if errno == EAGAIN || errno == EWOULDBLOCK {
            print("We have processed all incoming connections.")
            break;
          }
          else {
            perror("accept")
            break
          }
        }

        //print("in_len = ", in_len)
        //print("family = ", in_addr.memory.sa_family)

        var host=UnsafeMutablePointer<CChar>.alloc(Int(NI_MAXHOST))
        //var host=String(count: Int(NI_MAXSERV), repeatedValue: Character("\0"))
        var port=UnsafeMutablePointer<CChar>.alloc(Int(NI_MAXSERV))
        defer {
          host.dealloc(Int(NI_MAXHOST))
          port.dealloc(Int(NI_MAXSERV))
        }

        var s = getnameinfo(in_addr, in_len, host, UInt32(NI_MAXHOST), port, UInt32(NI_MAXSERV), 
                            NI_NUMERICHOST | NI_NUMERICSERV)

        if s == 0 {
          if let 
            h = String.fromCString(host),
            p = String.fromCString(port) {
              print("Accepted connection on descriptor ", infd, " host=", h, " port=", p)
            }
        }
        else {
          let msg = String.fromCString(gai_strerror(s)) ?? "No error description."
          print(msg)
        }

        if makeSocketNonBlocking(infd) == -1 {
          fatalError("Unable to make socket non-blocking")
        }

        event.memory.data.fd = infd
        event.memory.events = unsafeBitCast(EPOLLIN, UInt32.self) | unsafeBitCast(EPOLLET, UInt32.self)
        if epoll_ctl(efd, EPOLL_CTL_ADD, infd, event) == -1 {
          perror("epoll_ctl")
          abort()
        }
      }
      continue
    }
    else {
      /* We have data on the fd waiting to be read. Read and
         display it. We must read whatever data is available
         completely, as we are running in edge-triggered mode
         and won't get a notification again for the same
         data. */
      var done = false

      while true {
        let buffer = [CChar](count: 512, repeatedValue: 0)
        //let buffer = UnsafeMutablePointer<CChar>.alloc(512);
        //defer { buffer.dealloc(512) }

        let buf = UnsafeMutablePointer<CChar>(buffer)
        let count: Int = read(ev.data.fd, buf, 512)
        //print("Read: \(count)")
        if count == -1 {
          /* If errno == EAGAIN, that means we have read all
             data. So go back to the main loop. */
          if errno != EAGAIN {
            perror("read")
            done = true
          }
          break
        }
        else if count == 0 {
          /* End of file. The remote has closed the
             connection. */
          done = true
          break
        }
        
        if let str = String.fromCString(buffer) {
          print(str, terminator: "")
        }
      }
      if done == true {
        print("Closed connection on descriptor ", ev.data.fd)
        close(ev.data.fd)
      }
    }
  }
}

