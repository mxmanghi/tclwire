# tclwire
An incidentally created Tcl based application server
```mermaid
• flowchart TD
      Client["HTTP Client"]

      subgraph Runtime["Runtime Supervisor Thread"]
          Bootstrap["tclwire::runtime"]
          Reactor["TransportReactor"]
          Dispatcher["ApplicationDispatcher"]
      end

      subgraph Services["Global Service Threads"]
          TPBA["ThreadPoolsBrokerAgent"]
          Logger["Logger Agent"]
      end

      subgraph ConnectionPool["TPBA Pool: connection:http"]
          CA["ConnectionAgent"]
          HCA["HttpConnectionAgent"]
          Protocol["HttpProtocolSession"]
          Transactions["Outstanding Transaction Registry"]
      end

      subgraph ApplicationPool["TPBA Pool: app:default"]
          CGA["Content Generator Agent"]
          App["CApplication"]
          IO["tclwire::io"]
      end

      ErrorDB[("http_error_messages.json")]
      ErrorAPI["tclwire::http::errors"]

      Bootstrap -->|starts| TPBA
      Bootstrap -->|starts| Logger
      Bootstrap -->|creates| Dispatcher
      Bootstrap -->|creates| Reactor

      Dispatcher -->|creates/manages| ApplicationPool
      Reactor -->|creates/manages| ConnectionPool

      Client -->|TCP connection| Reactor
      Reactor -->|acquires worker| TPBA
      TPBA -->|connection worker ID| Reactor
      Reactor -->|transfers socket channel| HCA

      HCA -- inherits --> CA
      HCA -->|owns| Protocol
      HCA -->|maintains| Transactions

      Protocol -->|completion detection| HCA
      Protocol -->|parsed request descriptor| HCA

      HCA -->|request descriptor| Dispatcher
      Dispatcher -->|selects application by Host| App
      Dispatcher -->|acquires CGA worker| TPBA
      TPBA -->|application worker ID| Dispatcher
      Dispatcher -->|asynchronous request| CGA

      CGA -->|creates and invokes| App
      App -->|out / puts / flush| IO

      IO -->|thread::send output event| HCA
      HCA -->|buffers by transaction| Transactions

      IO -->|complete event| HCA
      HCA -->|response body| Protocol
      Protocol -->|HTTP framing| HCA
      HCA -->|write_and_close| CA
      CA -->|puts + flush on socket| Client

      ErrorDB -->|loaded by| ErrorAPI
      ErrorAPI -->|semantic error response| HCA
      HCA -->|HTTP framing| Protocol

      CGA -->|release worker| TPBA
      CA -->|connection finished| Reactor
      Reactor -->|release worker| TPBA

  Request flow

  Client
    -> TransportReactor
    -> HttpConnectionAgent
    -> HttpProtocolSession
    -> ApplicationDispatcher
    -> Content Generator Agent
    -> CApplication
    -> ::tclwire::io
    -> HttpConnectionAgent
    -> HttpProtocolSession
    -> ConnectionAgent
    -> Client socket

