
// Inverse hierarchical stick breaking transformation

#include "tensorflow/core/framework/op.h"
#include "tensorflow/core/framework/shape_inference.h"
#include "tensorflow/core/framework/op_kernel.h"
#include "tensorflow/core/util/work_sharder.h"
#include "tensorflow/core/lib/core/blocking_counter.h"


#include <thread>
#include <cstdio>
#include <functional>

using namespace tensorflow;

REGISTER_OP("HSB")
    .Input("y_logit: float32")
    .Input("left_index: int32")
    .Input("right_index: int32")
    .Input("leaf_index: int32")
    .Output("x: float32")
    .SetShapeFn([](shape_inference::InferenceContext* c) {
        shape_inference::ShapeHandle y_logit;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(0), 2, &y_logit));

        shape_inference::ShapeHandle unused;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(1), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(2), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(3), 2, &unused));

        shape_inference::DimensionHandle m = c->Dim(y_logit, 0);
        shape_inference::DimensionHandle n_minus_one = c->Dim(y_logit, 1);
        shape_inference::DimensionHandle n = c->MakeDim(c->Value(n_minus_one) + 1);
        c->set_output(0, c->MakeShape({m, n}));
        return Status::OK();
    });


class HSBOp : public OpKernel {
    public:
    explicit HSBOp(OpKernelConstruction* context) : OpKernel(context) {}

    void Compute(OpKernelContext* context) override {
        const Tensor& input_y_logit     = context->input(0);
        const Tensor& input_left_index  = context->input(1);
        const Tensor& input_right_index = context->input(2);
        const Tensor& input_leaf_index  = context->input(3);

        // TODO: check sizes

        const int64 m = input_y_logit.dim_size(0);
        const int64 n = input_y_logit.dim_size(1) + 1;

        Tensor* output_x = nullptr;
        OP_REQUIRES_OK(
            context, context->allocate_output(
                0, TensorShape({m, n}), &output_x));

        auto x           = output_x->flat_inner_dims<float>();
        auto y_logit     = input_y_logit.flat_inner_dims<float>();
        auto left_index  = input_left_index.flat_inner_dims<int32>();
        auto right_index = input_right_index.flat_inner_dims<int32>();
        auto leaf_index  = input_leaf_index.flat_inner_dims<int32>();

        std::unordered_map<size_t, std::vector<double>> us_map;
        mutex map_mutex;

        auto HSBBatch = [&, context](int64 start_batch, int64 limit_batch) {
            const std::thread::id thread_id = std::this_thread::get_id();
            const size_t id_hash = std::hash<std::thread::id>()(thread_id);

            map_mutex.lock();
            const auto key_count = us_map.count(id_hash);
            map_mutex.unlock();
            if (!key_count) {
                map_mutex.lock();
                us_map.emplace(
                    std::piecewise_construct, std::forward_as_tuple(id_hash),
                    std::forward_as_tuple(2*n - 1));
                map_mutex.unlock();
            }
            map_mutex.lock();
            auto& u_data = us_map[id_hash];
            map_mutex.unlock();

            for (int i = start_batch; i < limit_batch; ++i) {
                float* x_i = &x(i, 0);
                const float* y_logit_i = &y_logit(i, 0);
                const int32* left_index_i  = &left_index(i, 0);
                const int32* right_index_i = &right_index(i, 0);
                const int32* leaf_index_i  = &leaf_index(i, 0);

                u_data[0] = 1.0;
                int k = 0;
                for (int j = 0; j < 2*n-1; ++j) {
                    // leaf node
                    if (leaf_index_i[j] >= 0) {
                        x_i[leaf_index_i[j]] = u_data[j];
                    }
                    // internal node
                    else {
                        double y_ik = 1.0 / (1.0 + (double) exp(-y_logit_i[k]));
                        u_data[left_index_i[j]] = y_ik * u_data[j];
                        u_data[right_index_i[j]] = (1.0 - y_ik) * u_data[j];
                        ++k;
                    }
                }
            }
        };

        const int64 cost_est = n * 10; // total wild guess
        auto worker_threads = *(context->device()->tensorflow_cpu_worker_threads());
        Shard(worker_threads.num_threads, worker_threads.workers,
              m, cost_est, HSBBatch);
    }
};


REGISTER_KERNEL_BUILDER(Name("HSB").Device(DEVICE_CPU), HSBOp);


// TODO: HSBGrad
// We don't really need this for the time being. We only need HSBOp to generate
// samples from the likelihood function, which does not require a gradient.


REGISTER_OP("InvHSB")
    .Input("x: float32")
    .Input("left_index: int32")
    .Input("right_index: int32")
    .Input("leaf_index: int32")
    .Output("y: float64")
    .Output("ladj: float32")
    .SetShapeFn([](shape_inference::InferenceContext* c) {
        shape_inference::ShapeHandle x;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(0), 2, &x));

        shape_inference::ShapeHandle unused;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(1), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(2), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(3), 2, &unused));

        shape_inference::DimensionHandle m = c->Dim(x, 0);
        shape_inference::DimensionHandle n = c->Dim(x, 1);
        shape_inference::DimensionHandle n_minus_one = c->MakeDim(c->Value(n) - 1);
        c->set_output(0, c->MakeShape({m, n_minus_one}));
        c->set_output(1, c->MakeShape({m, 1}));
        return Status::OK();
    });


class InvHSBOp : public OpKernel {
    public:
    explicit InvHSBOp(OpKernelConstruction* context) : OpKernel(context) {}

    void Compute(OpKernelContext* context) override {
        const Tensor& input_x           = context->input(0);
        const Tensor& input_left_index  = context->input(1);
        const Tensor& input_right_index = context->input(2);
        const Tensor& input_leaf_index  = context->input(3);

        // TODO: check sizes

        const int64 m = input_x.dim_size(0);
        const int64 n = input_x.dim_size(1);

        Tensor* output_y = nullptr;
        OP_REQUIRES_OK(
            context, context->allocate_output(
                0, TensorShape({m, n-1}), &output_y));

        Tensor* output_ladj = nullptr;
        OP_REQUIRES_OK(
            context, context->allocate_output(
                1, TensorShape({m, 1}), &output_ladj));

        auto x           = input_x.flat_inner_dims<float>();
        auto y           = output_y->flat_inner_dims<double>();
        auto ladj        = output_ladj->flat_inner_dims<float>();
        auto left_index  = input_left_index.flat_inner_dims<int32>();
        auto right_index = input_right_index.flat_inner_dims<int32>();
        auto leaf_index  = input_leaf_index.flat_inner_dims<int32>();

        std::unordered_map<size_t, std::vector<double>> us_map;
        mutex map_mutex;

        auto InvHSBBatch = [&, context](int64 start_batch, int64 limit_batch) {
            // this is cribing from wals_solver_op.cc
            const std::thread::id thread_id = std::this_thread::get_id();
            const size_t id_hash = std::hash<std::thread::id>()(thread_id);

            map_mutex.lock();
            const auto key_count = us_map.count(id_hash);
            map_mutex.unlock();
            if (!key_count) {
                map_mutex.lock();
                us_map.emplace(
                    std::piecewise_construct, std::forward_as_tuple(id_hash),
                    std::forward_as_tuple(2*n - 1));
                map_mutex.unlock();
            }
            map_mutex.lock();
            auto& u_data = us_map[id_hash];
            map_mutex.unlock();

            // intermediate values
            // auto u_tens = Tensor(DT_DOUBLE, TensorShape({2*n - 1}));
            // auto u = u_tens.flat<double>();
            // double* u_data = &u(0);

            for (int i = start_batch; i < limit_batch; ++i) {
                const float* x_i = &x(i, 0);
                double* y_i = &y(i, 0);
                float* ladj_i = &ladj(i, 0);
                const int32* left_index_i  = &left_index(i, 0);
                const int32* right_index_i = &right_index(i, 0);
                const int32* leaf_index_i  = &leaf_index(i, 0);

                ladj_i[0] = 0.0;
                int k = n - 2;
                for (int j = 2*n-2; j >= 0; --j) {
                    // leaf node
                    if (leaf_index_i[j] >= 0) {
                        u_data[j] = x_i[leaf_index_i[j]];
                    }
                    // internal node
                    else {
                        double u_left = u_data[left_index_i[j]];
                        double u_right = u_data[right_index_i[j]];
                        u_data[j] = u_left + u_right;
                        y_i[k] = u_left / u_data[j];
                        ladj_i[0] -= log(u_data[j]);

                        --k;
                    }
                }
            }
        };

        const int64 cost_est = n * 10; // total wild guess
        auto worker_threads = *(context->device()->tensorflow_cpu_worker_threads());
        Shard(worker_threads.num_threads, worker_threads.workers,
              m, cost_est, InvHSBBatch);
    }
};


REGISTER_KERNEL_BUILDER(Name("InvHSB").Device(DEVICE_CPU), InvHSBOp);


REGISTER_OP("InvHSBGrad")
    .Input("y_grad: float64")
    .Input("ladj_grad: float32")
    .Input("y: float64")
    .Input("ladj: float32")
    .Input("left_index: int32")
    .Input("right_index: int32")
    .Input("leaf_index: int32")
    .Output("backprops: float32")
    .SetShapeFn([](shape_inference::InferenceContext* c) {
        shape_inference::ShapeHandle y;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(0), 2, &y));

        shape_inference::ShapeHandle unused;
        TF_RETURN_IF_ERROR(c->WithRank(c->input(1), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(2), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(3), 2, &unused));
        TF_RETURN_IF_ERROR(c->WithRank(c->input(4), 2, &unused));

        shape_inference::DimensionHandle m = c->Dim(y, 0);
        shape_inference::DimensionHandle n_minus_one = c->Dim(y, 1);
        shape_inference::DimensionHandle n = c->MakeDim(c->Value(n_minus_one) + 1);

        c->set_output(0, c->MakeShape({m, n}));
        return Status::OK();
    });


class InvHSBGradOp : public OpKernel {
    public:
    explicit InvHSBGradOp(OpKernelConstruction* context) : OpKernel(context) {}

    void Compute(OpKernelContext* context) override {
        const Tensor& input_y_grad      = context->input(0);
        const Tensor& input_ladj_grad   = context->input(1);
        const Tensor& input_y           = context->input(2);
        const Tensor& input_ladj        = context->input(3);
        const Tensor& input_left_index  = context->input(4);
        const Tensor& input_right_index = context->input(5);
        const Tensor& input_leaf_index  = context->input(6);

        const int64 m = input_y.dim_size(0);
        const int64 n = input_y.dim_size(1) + 1;

        Tensor* output_backprops = nullptr;
        OP_REQUIRES_OK(
            context, context->allocate_output(
                0, TensorShape({m, n}), &output_backprops));

        auto y_grad      = input_y_grad.flat_inner_dims<double>();
        auto ladj_grad   = input_ladj_grad.flat_inner_dims<float>();
        auto y           = input_y.flat_inner_dims<double>();
        auto backprops   = output_backprops->flat_inner_dims<float>();
        auto left_index  = input_left_index.flat_inner_dims<int32>();
        auto right_index = input_right_index.flat_inner_dims<int32>();
        auto leaf_index  = input_leaf_index.flat_inner_dims<int32>();

        std::unordered_map<size_t, std::pair<std::vector<double>, std::vector<double>>> uvs_map;
        mutex map_mutex;

        auto InvHSBGradBatch = [&, context](int start_batch, int limit_batch) {
            // intermediate values storing subtree sums
            // auto u_tens = Tensor(DT_DOUBLE, TensorShape({2*n - 1}));
            // auto u = u_tens.flat<double>();
            // double* u_data = &u(0);

            // intermediate values storing gradients wrt subtree sums
            // auto v_tens = Tensor(DT_DOUBLE, TensorShape({2*n - 1}));
            // auto v = v_tens.flat<double>();
            // double* v_data = &v(0);

            const std::thread::id thread_id = std::this_thread::get_id();
            const size_t id_hash = std::hash<std::thread::id>()(thread_id);

            map_mutex.lock();
            const auto key_count = uvs_map.count(id_hash);
            map_mutex.unlock();
            if (!key_count) {
                map_mutex.lock();
                uvs_map.emplace(
                    std::piecewise_construct, std::forward_as_tuple(id_hash),
                    std::forward_as_tuple(
                        std::vector<double>(2*n - 1), std::vector<double>(2*n - 1)));
                map_mutex.unlock();
            }
            map_mutex.lock();
            auto& u_data = uvs_map[id_hash].first;
            auto& v_data = uvs_map[id_hash].second;
            map_mutex.unlock();

            for (int i = start_batch; i < limit_batch; ++i) {
                const double* y_grad_i = &y_grad(i, 0);
                const float* ladj_grad_i = &ladj_grad(i, 0);
                const double* y_i = &y(i, 0);
                float* backprops_i = &backprops(i, 0);
                const int32* left_index_i  = &left_index(i, 0);
                const int32* right_index_i = &right_index(i, 0);
                const int32* leaf_index_i  = &leaf_index(i, 0);

                u_data[0] = 1.0;
                v_data[0] = 0.0;
                int k = 0;
                for(int j = 0; j < 2*n-1; ++j) {
                    // leaf node
                    if (leaf_index_i[j] >= 0) {
                        backprops_i[leaf_index_i[j]] = v_data[j];
                    }
                    // internal node
                    else {
                        // double y_logit_ik = y_logit_i[k];
                        // double y = 1.0 / (1.0 + exp(-y_logit_ik));
                        double y = y_i[k];

                        double u_j = u_data[j];
                        double u_left = u_j * y;
                        double u_right = u_j * (1.0 - y);

                        // y = log(u_left/u_right)
                        // or
                        // y = u_left / (u_left + u_right)

                        // derivative of ladj wrt u_j
                        double dladj_du = -1.0/u_j;

                        double u_j2 = u_j * u_j;

                        v_data[left_index_i[j]] =
                            dladj_du * ladj_grad_i[0] +
                            v_data[j] + (u_right/u_j2) * y_grad_i[k];
                        v_data[right_index_i[j]] =
                            dladj_du * ladj_grad_i[0] +
                            v_data[j] - (u_left/u_j2) * y_grad_i[k];

                        u_data[left_index_i[j]] = u_left;
                        u_data[right_index_i[j]] = u_right;

                        ++k;
                    }
                }
            }
        };

        const int64 cost_est = n * 10; // total wild guess
        auto worker_threads = *(context->device()->tensorflow_cpu_worker_threads());
        Shard(worker_threads.num_threads, worker_threads.workers,
              m, cost_est, InvHSBGradBatch);
    }
};


REGISTER_KERNEL_BUILDER(Name("InvHSBGrad").Device(DEVICE_CPU), InvHSBGradOp);

