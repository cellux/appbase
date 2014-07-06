#include <string>
#include <vector>
#include <map>
#include <set>
#include <memory>
#include <fstream>

#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/stat.h>

#include <zmq.hpp>
#include <jack/jack.h>

/*** various helpers ***/

#define LOG(...) do {                                               \
    fprintf(stdout, __VA_ARGS__);                                   \
    fprintf(stdout, "\n");                                          \
  } while(0)

#define DIE(...) do {                                               \
    fprintf(stderr, "Error in %s line #%d:\n", __FILE__, __LINE__); \
    LOG(__VA_ARGS__);                                               \
    exit(1);                                                        \
  } while(0)

#define CHECK(expr, ...) if (!(expr)) DIE(__VA_ARGS__)

/*** typedefs ***/

typedef std::string ClientLocalName;   /* instrument */
typedef std::string ClientGlobalName;  /* orchestra.part.instrument */

typedef std::string PortName;       /* out */
typedef std::string PortLocalName;  /* instrument:out */
typedef std::string PortGlobalName; /* orchestra.part.instrument:out */

/*** messages ***/

enum showtime_msg_type {
  /* signals */
  SHOWTIME_SIGNAL_RECEIVED,
  /* jack */
  SHOWTIME_JACK_PORT_REGISTRATION,
  SHOWTIME_JACK_CLIENT_REGISTRATION
};

#define SHOWTIME_MAX_CLIENT_GLOBAL_NAME_LENGTH 128

struct showtime_msg_t {
  showtime_msg_type type;
  /* signals */
  int signum;
  int pid;
  /* jack */
  jack_port_id_t port;
  int reg;
  char name[SHOWTIME_MAX_CLIENT_GLOBAL_NAME_LENGTH+1];
};

class Patch {
public:
  Patch(const char *path)
    : path_(path)
  {
    reload();
  }

  void reload() {
    connections_.clear();
    std::ifstream in(path_);
    if (! in.good()) {
      DIE("cannot open patch file: %s", path_);
    }
    std::string src, dst;
    std::string item;
    State st = START;
    while (in) {
      in >> item;
      if (item.empty()) {
        break; // eof
      }
      int colon_pos = item.find(':');
      if (colon_pos != std::string::npos) {
        if (st == START) {
          src = item;
          st = LHS_ASSIGNED;
        }
        else if (st == RIGHT_ARROW) {
          dst = item;
          st = RHS_ASSIGNED;
        }
        else if (st == LEFT_ARROW) {
          dst = src;
          src = item;
          st = RHS_ASSIGNED;
        }
      }
      else if (item == "->") {
        st = RIGHT_ARROW;
      }
      else if (item == "<-") {
        st = LEFT_ARROW;
      }
      else {
        DIE("parse error");
      }
      if (st == RHS_ASSIGNED) {
        //LOG("parsed connection: %s -> %s", src.c_str(), dst.c_str());
        connections_.push_back(Connection(src, dst));
        st = START;
      }
    }
  }

  std::vector<PortLocalName> get_src_ports_for_dst(const PortLocalName& dst_port_name) {
    std::vector<PortLocalName> result;
    for (const auto &c : connections_) {
      if (c.second == dst_port_name) {
        result.push_back(c.first);
      }
    }
    return result;
  }

  std::vector<PortLocalName> get_dst_ports_for_src(const PortLocalName& src_port_name) {
    std::vector<PortLocalName> result;
    for (const auto &c : connections_) {
      if (c.first == src_port_name) {
        result.push_back(c.second);
      }
    }
    return result;
  }

private:
  typedef std::pair<PortLocalName, PortLocalName> Connection; // src -> dst
  const char *path_;
  enum State {
    START,
    LHS_ASSIGNED,
    RIGHT_ARROW,
    LEFT_ARROW,
    RHS_ASSIGNED
  };
  std::vector<Connection> connections_;
};

class JackConnection {
public:
  JackConnection(zmq::context_t &zmq_ctx, const ClientGlobalName &client_global_name)
    : zmq_ctx_(zmq_ctx)
  {
    jack_options_t jack_options = (jack_options_t) (JackNoStartServer | JackUseExactName);
    jack_client_ = jack_client_open(client_global_name.c_str(), jack_options, 0);
    CHECK(jack_client_, "jack_client_open() failed");
    LOG("connected to jackd with client name=[%s]", client_global_name.c_str());
    if (jack_set_thread_init_callback(jack_client_,
                                      jack_thread_init_callback,
                                      this))
      DIE("jack_set_thread_init_callback() failed");
    if (jack_set_client_registration_callback(jack_client_,
                                              jack_client_registration_callback,
                                              this))
      DIE("jack_set_client_registration_callback() failed");
    if (jack_set_port_registration_callback(jack_client_,
                                            jack_port_registration_callback,
                                            this))
      DIE("jack_set_port_registration_callback() failed");
    start();
  }

  ~JackConnection() {
    stop();
    jack_client_close(jack_client_);
    LOG("disconnected from jackd");
    /* the 0MQ socket should be closed in the jack thread, but I don't
       know how to do that */
  }

  jack_port_t *port_by_id(jack_port_id_t port) {
    return jack_port_by_id(jack_client_, port);
  }

  jack_port_t *port_by_name(const char *port_name) {
    return jack_port_by_name(jack_client_, port_name);
  }

  jack_port_t *port_by_name(const std::string& port_name) {
    return jack_port_by_name(jack_client_, port_name.c_str());
  }

  bool port_exists(const PortGlobalName& port_name) {
    return port_by_name(port_name) != 0;
  }

  const char* port_name(const jack_port_t *port) {
    return jack_port_name(port);
  }

  const char* port_name(jack_port_id_t port) {
    return port_name(port_by_id(port));
  }

  const char* port_type(jack_port_t *port) {
    return jack_port_type(port);
  }

  int port_flags(jack_port_t *port) {
    return jack_port_flags(port);
  }

  void connect(const PortGlobalName& src, const PortGlobalName& dst) {
    if (jack_connect(jack_client_, src.c_str(), dst.c_str())) {
      LOG("warning: cannot make connection %s -> %s", src.c_str(), dst.c_str());
    }
  }

  jack_port_t *port_register(std::string &port_name,
                             const char* port_type,
                             unsigned long flags) {
    return jack_port_register(jack_client_,
                              port_name.c_str(),
                              port_type,
                              flags,
                              0);
  }

private:
  void start() {
    if (jack_activate(jack_client_))
      DIE("jack_activate() failed");
  }

  void stop() {
    if (jack_deactivate(jack_client_))
      DIE("jack_deactivate() failed");
  }

  static void jack_thread_init_callback(void *arg) {
    JackConnection *jc = (JackConnection*) arg;
    /* this callback gets called in two different threads - I don't know
       why - so we must be careful to avoid double initialization of the
       client socket */
    if (!jc->client_socket_) {
      jc->client_socket_.reset(new zmq::socket_t(jc->zmq_ctx_, ZMQ_PUB));
      jc->client_socket_->connect("inproc://messages");
    }
  }

  static void jack_port_registration_callback(jack_port_id_t port,
                                              int reg,
                                              void *arg) {
    JackConnection *jc = (JackConnection*) arg;
    showtime_msg_t msg;
    msg.type = SHOWTIME_JACK_PORT_REGISTRATION;
    msg.port = port;
    msg.reg = reg;
    if (jc->client_socket_->send(&msg, sizeof(msg)) != sizeof(msg))
      DIE("error while sending jack event message from port registration callback");
  }

  static void jack_client_registration_callback(const char *client_global_name,
                                                int reg,
                                                void *arg) {
    JackConnection *jc = (JackConnection*) arg;
    showtime_msg_t msg;
    msg.type = SHOWTIME_JACK_CLIENT_REGISTRATION;
    if (strlen(client_global_name) > SHOWTIME_MAX_CLIENT_GLOBAL_NAME_LENGTH)
      DIE("jack client registration callback: client name too long");
    strcpy(msg.name, client_global_name);
    msg.reg = reg;
    if (jc->client_socket_->send(&msg, sizeof(msg)) != sizeof(msg))
      DIE("error while sending jack event message from client registration callback");
  }

private:
  zmq::context_t& zmq_ctx_;
  std::unique_ptr<zmq::socket_t> client_socket_;
  jack_client_t *jack_client_;
};

class SignalManager {
public:
  SignalManager(zmq::context_t &zmq_ctx) 
    : zmq_ctx_(zmq_ctx)
  {
    sigset_t ss;
    sigfillset(&ss);
    /* block all signals in main thread */
    if (pthread_sigmask(SIG_BLOCK, &ss, &saved_sigset_) != 0) {
      DIE("pthread_sigmask() failed\n");
    }
    /* signals are handled in a dedicated thread which sends a 0MQ
       message to the main thread when a signal arrives */
    if (pthread_create(&signal_handler_thread_,
                       NULL,
                       signal_handler_thread,
                       this) != 0) {
      DIE("cannot create signal handler thread: pthread_create() failed\n");
    }
  }

  ~SignalManager() {
    if (pthread_join(signal_handler_thread_, NULL))
      DIE("pthread_join() failed for signal handler thread");
    /* restore signal mask */
    if (pthread_sigmask(SIG_SETMASK, &saved_sigset_, NULL) != 0)
      DIE("cannot restore signal mask: pthread_sigmask() failed");
  }

  static bool is_termination_signal(int signum) {
    return (signum == SIGTERM || signum == SIGINT);
  }

private:
  static void *signal_handler_thread(void *arg) {
    SignalManager *sm = (SignalManager*) arg;
    sigset_t ss;
    siginfo_t siginfo;
    sigfillset(&ss);
    showtime_msg_t msg;
    int signum;
    zmq::socket_t sock(sm->zmq_ctx_, ZMQ_PUB);
    sock.connect("inproc://messages");
    for (;;) {
      signum = sigwaitinfo(&ss, &siginfo);
      if (signum < 0) {
        DIE("sigwait() failed\n");
      }
      msg.type = SHOWTIME_SIGNAL_RECEIVED;
      msg.signum = signum;
      msg.pid = siginfo.si_pid;
      if (sock.send(&msg, sizeof(msg)) != sizeof(msg))
        DIE("zmq_send() failed in signal handler thread");
      if (is_termination_signal(signum))
        break;
    }
  }

private:
  zmq::context_t &zmq_ctx_;
  pthread_t signal_handler_thread_;
  sigset_t saved_sigset_;
};

class Child {
public:
  Child(const std::string &prefix, const std::string &client_local_name)
    : prefix_(prefix),
      client_local_name_(client_local_name),
      pid_(0)
  {}

  bool valid() {
    std::string run_path = client_local_name_+"/run";
    return access(run_path.c_str(), X_OK) == 0;
  }

  bool running() {
    return pid_ ? kill(pid_,0)==0 : false;
  }

  void start() {
    LOG("starting child: %s", client_local_name_.c_str());
    pid_t pid = fork();
    if (pid==0) {
      // child
      std::string client_global_name = prefix_+"."+client_local_name_;
      CHECK(chdir(client_local_name_.c_str())==0, "chdir() to child root failed: %s", client_local_name_.c_str());
      execl("./run", client_local_name_.c_str(), client_global_name.c_str(), 0);
      DIE("execl() failed");
    }
    // parent
    pid_ = pid;
  }

  void stop() {
    if (pid_) {
      LOG("killing child: %s", client_local_name_.c_str());
      kill(pid_, SIGTERM);
    }
  }

  pid_t pid() { return pid_; }
  void clear_pid() { pid_ = 0; }

private:
  std::string prefix_;
  std::string client_local_name_;
  pid_t pid_;
};

class ChildManager {
public:
  ChildManager(const std::string &prefix)
    : prefix_(prefix)
  {}

  ~ChildManager() {
    stop_children();
  }

  bool child_exists(std::string &client_local_name) {
    return children_.find(client_local_name) != children_.end();
  }

  void add_child(std::string client_local_name) {
    children_.insert(ChildMap::value_type(client_local_name, Child(prefix_, client_local_name)));
  }

  void remove_child(std::string client_local_name) {
    children_.erase(client_local_name);
  }

  void discover_children() {
    struct stat st;
    int rv;
    struct dirent *entry;
    DIR *dir;

    dir = opendir(".");
    CHECK(dir, "opendir() failed");
    while (entry = readdir(dir)) {
      if (strcmp(entry->d_name, ".")==0 ||
          strcmp(entry->d_name, "..")==0)
        continue;
      rv = stat(entry->d_name, &st);
      CHECK(rv==0, "stat() failed on %s", entry->d_name);
      if (S_ISDIR(st.st_mode)) {
        std::string client_local_name(entry->d_name);
        std::string run_path = client_local_name+"/run";
        if (access(run_path.c_str(), X_OK) == 0) {
          if (! child_exists(client_local_name)) {
            add_child(client_local_name);
          }
        }
      }
    }
    closedir(dir);
  }

  void forget_children() {
    children_.clear();
  }

  void start_children() {
    for (auto &e : children_) {
      Child &c = e.second;
      if (! c.running()) {
        c.start();
      }
    }
  }

  void stop_children() {
    for (auto &e : children_) {
      Child &c = e.second;
      if (c.running()) {
        c.stop();
      }
    }
  }

  void stop_invalid_children() {
    for (auto &e : children_) {
      Child &c = e.second;
      if (!c.valid()) {
        if (c.running()) {
          c.stop();
        }
        children_.erase(e.first);
      }
    }
  }

  void sigchld(int pid) {
    for (auto &e : children_) {
      Child &c = e.second;
      if (c.pid() == pid) {
        LOG("got SIGCHLD for %d, clearing pid in child", pid);
        c.clear_pid();
        break;
      }
    }
  }

private:
  typedef std::map<std::string, Child> ChildMap;
  ChildMap children_;
  std::string prefix_;
};

class Options {
public:
  Options(int argc, char **argv) {
    int i=1;
    while (i < argc) {
      client_global_name_ = argv[i];
      i++;
    }
  }
  const ClientGlobalName &client_global_name() {
    return client_global_name_;
  }

private:
  ClientGlobalName client_global_name_;
};

class ShowTime {
public:
  ShowTime(int argc, char **argv)
    : /* Options */ opt_(argc, argv),
      /* zmq::context_t */ zmq_ctx_(),
      /* zmq::socket_t */ sub_sock_(zmq_ctx_, ZMQ_SUB),
      /* SignalManager */ sm_(zmq_ctx_),
      /* JackConnection */ jc_(zmq_ctx_, opt_.client_global_name()),
      /* ChildManager */ cm_(opt_.client_global_name()),
      /* Patch */ patch_("patch")
  {
  }

  void run() {
    sub_sock_.bind("inproc://messages");
    sub_sock_.setsockopt(ZMQ_SUBSCRIBE, 0, 0);
    cm_.discover_children();
    cm_.start_children();
    showtime_msg_t msg;
    bool running = true;
    zmq::pollitem_t poll_item = { (void*) sub_sock_, 0, ZMQ_POLLIN, 0 };
    while (running) {
      int nevents = zmq::poll(&poll_item, 1, -1);
      if (nevents == 0)
        continue;
      if (sub_sock_.recv(&msg, sizeof(msg)) != sizeof(msg))
        DIE("zmq_recv() failed in main thread when receiving message");
      switch (msg.type) {
      case SHOWTIME_SIGNAL_RECEIVED: {
        //LOG("got signal #%d: %s", msg.signum, strsignal(msg.signum));
        if (msg.signum == SIGCHLD) {
          cm_.sigchld(msg.pid);
        }
        if (SignalManager::is_termination_signal(msg.signum)) {
          running = false;
        }
        break;
      }
      case SHOWTIME_JACK_PORT_REGISTRATION: {
        const char *port_global_name = jc_.port_name(msg.port);
        if (msg.reg) {
          LOG("registered jack port: %s", port_global_name);
          handle_port_registration(port_global_name);
        }
        else {
          LOG("unregistered jack port: %s", port_global_name);
        }
        break;
      }
      case SHOWTIME_JACK_CLIENT_REGISTRATION: {
        const char *client_global_name = msg.name;
        if (msg.reg) {
          LOG("registered jack client: %s", client_global_name);
        }
        else {
          LOG("unregistered jack client: %s", client_global_name);
        }
        break;
      }
      default:
        DIE("unknown msg.type in received message: %d", msg.type);
      }
    }
    cm_.stop_children();
    cm_.forget_children();
  }

private:
  bool is_our_child(const ClientGlobalName& child_name) {
    const ClientGlobalName& our_name = opt_.client_global_name();
    int our_length = our_name.length();
    return (child_name.length() > our_length &&
            child_name.substr(0, our_length) == our_name &&
            child_name[our_length]=='.' &&
            child_name.find('.', our_length+1)==std::string::npos);
  }

  ClientLocalName client_name_global_to_local(const ClientGlobalName& client_global_name) {
    int last_dot_pos = client_global_name.rfind('.');
    return client_global_name.substr(last_dot_pos+1);
  }

  PortLocalName port_name_global_to_local(const PortGlobalName port_name) {
    const ClientGlobalName& our_name = opt_.client_global_name();
    int our_length = our_name.length();
    return port_name.substr(our_length+1);
  }

  PortGlobalName port_name_local_to_global(const PortLocalName& port_name) {
    const ClientGlobalName& our_name = opt_.client_global_name();
    if (port_name[0]==':') {
      // our own port
      return our_name+port_name;
    }
    else {
      // a child's port
      return our_name+"."+port_name;
    }
  }

  void handle_port_registration(const char *name) {
    jack_port_t *port = jc_.port_by_name(name);
    const char* port_type = jc_.port_type(port);
    unsigned long port_flags = jc_.port_flags(port);
    PortGlobalName port_global_name(name);
    int colon_pos = port_global_name.find(":");
    ClientGlobalName left = port_global_name.substr(0, colon_pos);
    PortName right = port_global_name.substr(colon_pos+1);
    if (is_our_child(left)) {
      PortLocalName port_local_name = port_name_global_to_local(port_global_name);
      for (const PortLocalName& dst_port_name : patch_.get_dst_ports_for_src(port_local_name)) {
        if (dst_port_name[0]==':') {
          PortName pn = dst_port_name.substr(1);
          PortGlobalName pgn = opt_.client_global_name()+":"+pn;
          if (! jc_.port_exists(pgn)) {
            const char *ptype = port_type; // same as src
            unsigned long pflags = (port_flags & JackPortIsInput) ?
              JackPortIsOutput : JackPortIsInput;
            CHECK(jc_.port_register(pn, ptype, pflags), "cannot register port: %s", pgn.c_str());
          }
        }
        jc_.connect(port_global_name, port_name_local_to_global(dst_port_name));
      }
      for (const PortLocalName& src_port_name : patch_.get_src_ports_for_dst(port_local_name)) {
        if (src_port_name[0]==':') {
          PortName pn = src_port_name.substr(1);
          PortGlobalName pgn = opt_.client_global_name()+":"+pn;
          if (! jc_.port_exists(pgn)) {
            const char *ptype = port_type; // same as dst
            unsigned long pflags = (port_flags & JackPortIsInput) ?
              JackPortIsOutput : JackPortIsInput;
            CHECK(jc_.port_register(pn, ptype, pflags), "cannot register port: %s", pgn.c_str());
          }
        }
        jc_.connect(port_name_local_to_global(src_port_name), port_global_name);
      }
    }
  }

  Options opt_;
  zmq::context_t zmq_ctx_;
  zmq::socket_t sub_sock_;
  SignalManager sm_;
  JackConnection jc_;
  ChildManager cm_;
  Patch patch_;
};

static void showUsage() {
  printf("Usage: showtime <client-name>\n");
}

int main(int argc, char **argv) {
  if (argc < 2) {
    showUsage();
  }
  else {
    std::auto_ptr<ShowTime> st(new ShowTime(argc, argv));
    st->run();
  }
  return 0;
}
