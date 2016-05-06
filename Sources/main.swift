import Foundation
import Glibc
import GlibcExtras

protocol EventsSource: class {

}

enum SocketError: ErrorProtocol {
  case GetAddress(String?)
  case Create
  case Bind
  case FlagSet
  case Listen
}

class Socket:EventsSource {
  let port: String

  private var _socket: Int32 = 0
  var socket: Int32 { 
    get {
      return self._socket 
    }
  }

  init(port: String) throws {
    self.port = port
    self._socket = try createAndBind(port: port)
  }

  deinit {
    Glibc.close(self._socket);
  }

  private func createAndBind(port: String) throws -> Int32 {
    var hints = UnsafeMutablePointer<addrinfo>(allocatingCapacity: 1)
    defer { hints.deallocateCapacity(1) }

    hints.pointee.ai_family = AF_UNSPEC
    hints.pointee.ai_socktype = unsafeBitCast(SOCK_STREAM, to: Int32.self)
    hints.pointee.ai_flags = AI_PASSIVE

    var result = UnsafeMutablePointer<addrinfo>(nil)
    defer { freeaddrinfo(result) }
    let res = getaddrinfo(nil, port, hints, &result)

    //print(res)
    if res != 0 {
      throw SocketError.GetAddress(String(cString: gai_strerror(res)))
    }

    var sfd:Int32 = -1
    var rp = result;
    repeat {
      sfd = Glibc.socket(rp!.pointee.ai_family, rp!.pointee.ai_socktype, rp!.pointee.ai_protocol)

      if sfd == -1 { 
        throw SocketError.Create
      }

      let s = bind(sfd, rp!.pointee.ai_addr, rp!.pointee.ai_addrlen)
      if s == 0 { 
        //print("Socket bound successfully")
        break 
      }
      
      close(sfd)
      sfd = -1
      rp = UnsafeMutablePointer<addrinfo>(rp!.pointee.ai_next)
    } while rp != nil
    
    if sfd == -1 {
      throw SocketError.Bind
    }

    return sfd
  }

  func makeNonBlocking() throws -> Socket {
    let flags = Glibc.fcntl(self.socket, F_GETFL, 0)
    if flags == -1 {
      //print("Unable to get socket flags")
      throw SocketError.FlagSet
    }

    let newFlags = flags | O_NONBLOCK
    let s = Glibc.fcntl(self.socket, F_SETFL, newFlags)
    if s == -1 {
      //print("Unable to set non-blocking flag")
      throw SocketError.FlagSet
    }
    return self
  }

  func listen() throws -> Socket {
    if Glibc.listen(self.socket, SOMAXCONN) == -1 {
      throw SocketError.Listen
    }
    return self
  }
}

enum EPollError: ErrorProtocol {
  case Create
  case Add
}

enum EventError: ErrorProtocol {
  case HangUp(Socket)
  case Error(Socket)
}

class EPoll {
  private var _fd: Int32
  var descriptor: Int32 { get { return self._fd } }
  let maxEvents: Int32

  init(max:Int32) throws {
    self.maxEvents = max
    self._fd = epoll_create1(0)
    if self._fd == -1 {
      throw EPollError.Create;
    }
  }

  func addDescriptor(_ fd:Int32, fromEventsSource source:Socket) throws -> EPoll {
    let event = UnsafeMutablePointer<epoll_event>(allocatingCapacity: 1)
    defer { event.deallocateCapacity(1) }
    event.pointee.data.fd = fd
    // set event.pointee.data.ptr to the address of s
    // This way, when we get the events list we can dereference the pointer and
    // call the callback
    event.pointee.data.ptr = Unmanaged.passUnretained(source).toOpaque()
    event.pointee.events = unsafeBitCast(EPOLLIN, to: UInt32.self) | unsafeBitCast(EPOLLET, to: UInt32.self)

    if epoll_ctl(self._fd, EPOLL_CTL_ADD, fd, event) == -1 {
      throw EPollError.Add
    }
    return self
  }

  func loop(cb:(Socket) -> Void, errcb:(EventError) -> Void) {
    // Buffer where events are returned
    let events = UnsafeMutablePointer<epoll_event>(allocatingCapacity: Int(self.maxEvents))
    defer { events.deallocateCapacity(Int(self.maxEvents)) }
    var n = 0
    while true {
      n = Int(epoll_wait(self._fd, events, self.maxEvents, -1))
      for i in 0..<n {
        let ev = events[i]
        if ev.events & unsafeBitCast(EPOLLERR, to: UInt32.self) != 0 || 
           ev.events & unsafeBitCast(EPOLLHUP, to: UInt32.self) != 0 ||
           ev.events & unsafeBitCast(EPOLLIN, to: UInt32.self) == 0 {
          // the socket address should be dereferenced from the ev.pointee.events.ptr
          // then cb should be called with that socket
          //let s = self._sockets.filter { $0.socket !== unsafeBitCast(ev.data.fd, to: Int32.self) }
          //errcb(EventError.HangUp(s))
          Glibc.close(ev.data.fd)
          continue
        }
      }
    }
  }
}

let socket: Socket?
let eventPoll: EPoll?
do {
  socket = try Socket(port: "8080").makeNonBlocking().listen()
  eventPoll = try EPoll(max: 64).addDescriptor(socket!.socket, fromEventsSource: socket!)
} catch _ {
  fatalError("Unable to create or configure socket")
}

/* The event loop */
/*
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
    else if socket.socket == ev.data.fd {
      while true {
        let in_addr = UnsafeMutablePointer<sockaddr>(allocatingCapacity: 1)
        defer { in_addr.deallocateCapacity(1) }
        var in_len:UInt32 = UInt32(sizeof(sockaddr))
        let infd = accept(socket.socket, in_addr, &in_len)
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
        //print("family = ", in_addr.pointee.sa_family)

        var host=UnsafeMutablePointer<CChar>(allocatingCapacity: Int(NI_MAXHOST))
        //var host=String(count: Int(NI_MAXSERV), repeatedValue: Character("\0"))
        var port=UnsafeMutablePointer<CChar>(allocatingCapacity: Int(NI_MAXSERV))
        defer {
          host.deallocateCapacity(Int(NI_MAXHOST))
          port.deallocateCapacity(Int(NI_MAXSERV))
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

        event.pointee.data.fd = infd
        event.pointee.events = unsafeBitCast(EPOLLIN, to: UInt32.self) | unsafeBitCast(EPOLLET, to: UInt32.self)
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
        //let buffer = UnsafeMutablePointer<CChar>(allocateCapacity: 512);
        //defer { buffer.deallocateCapacity(512) }

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
*/
